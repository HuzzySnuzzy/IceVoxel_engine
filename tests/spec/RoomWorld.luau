--[[
	The server's rooms (Seasons/RoomWorld) over a fake world (tests/lib/FakeRooms) and a fake game:
	players' seeds filled within the frame's budget, the cache answering without fills, block
	changes refilling only what they touch (a door toggled, a torch put down, a wall built across, a
	wall knocked through) with the air inherited by volume, an open room remembered as none for a
	while, rooms forgotten unless a source lives in them, machines seeding rooms near players,
	climateAt summing the heat for the call, temperatureAt in cells, walls and the eaves, sources'
	limits, a source in a wall between two rooms heating one (and paid for once), two thermostats
	sharing a room, a room whose roof is blown off going at once, a burning stove finding its room
	alone, no rooms at all (a space heater beside players, standing by with nobody near, by their
	positions), the sheltered outside value, a heater's thermostat holding a room through
	climateAt, and the fill's cost.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local FakeRooms = require("../lib/FakeRooms")

-- Server Seasons/RoomWorld's source, loaded afresh with its Roblox globals as arguments (after the
-- --! lines) where a test starts it.
local SOURCE = "src/server/Seasons/RoomWorld.luau"

local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = "local script, require, game = ...; " .. (lines[i] or "")
	return table.concat(lines, "\n")
end

return function(t, shared, require, server)
	local Biomes = require(shared.Biomes)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local DayCycle = require(shared.DayCycle)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Rooms = require(shared.Seasons.Rooms)
	local HeatStates = require(shared.Seasons.HeatStates)
	local Temperature = require(shared.ToughAsNails.Temperature)
	local RoomWorld = require(server.Seasons.RoomWorld)

	local B = Blocks.id
	local G = FakeRooms.GROUND
	local SETTINGS = Config.Seasons.Rooms
	local HEAT = Config.Seasons.Heat
	local PLAINS = (Biomes.byName("Plains") :: any).index

	-- A fake game round `world`: players' feet in `players`, a clock moved by hand, sources by block
	-- (output and limit), the outside fixed.
	local function game(world: any, options: any?): any
		local opts = options or {}
		local fake = {
			players = {} :: { { number } },
			now = 0,
			outside = opts.outside or -6.7,
			sources = opts.sources or {},
		}
		fake.env = {
			getBlock = world.getBlock,
			skyAbove = world.skyAbove,
			column = function(): (number, number)
				return G, PLAINS
			end,
			dayTime = function(): number
				return 18000
			end,
			players = function(each: (number, number, number) -> ())
				for _, p in fake.players do
					each(p[1], p[2], p[3])
				end
			end,
			clock = function(): number
				return fake.now
			end,
			seed = 7,
			roomSource = function(block: number): (any, number?)
				local source = fake.sources[block]
				if source then
					return source.output, source.limit
				end
				return nil, nil
			end,
			playerHU = HEAT.Player,
			outside = if opts.climate
				then nil
				else function(): number
					return fake.outside
				end,
		}
		fake.rooms = RoomWorld.new(fake.env)
		-- Runs `seconds` of frames of `dt`.
		function fake.run(seconds: number, dt: number?)
			local step = dt or 1
			for _ = 1, math.max(1, math.round(seconds / step)) do
				RoomWorld.stepWorld(fake.rooms, step)
			end
		end
		return fake
	end

	-- A game's options with one kind of room source.
	local function sourced(block: number, output: () -> number, limit: number?): any
		return { sources = { [block] = { output = output, limit = limit } } }
	end

	local function campfire(): number
		return HEAT.Campfire
	end

	local function plankHouse(x0: number?, z0: number?): any
		local world = FakeRooms.new(Blocks, Rooms)
		local x, z = x0 or 0, z0 or 0
		local front = world.house(x, z, 5, 5, 3, B.Planks)
		world.set(x + 2, G, front, B.OakDoor)
		world.set(x + 2, G + 1, front, B.OakDoorTop)
		return world
	end

	local function change(fake: any, world: any, x: number, y: number, z: number, block: number)
		local old = world.get(x, y, z)
		world.set(x, y, z, block)
		RoomWorld.changed(fake.rooms, x, y, z, old, block)
	end

	t.test("roomworld: a player's seed is filled within the frame's budget, then answered from the cache", function()
		local world = plankHouse()
		local fake = game(world)
		fake.players = { { 2.5, G, 2.5 } }
		t.eq(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5), nil, "not known yet: queued")
		t.eq(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5), nil, "queued once")
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(fake.rooms.fills, 1)
		local sample = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		t.eq(sample.volume, 75)
		t.near(sample.uaOut, 83 * 0.025 + 0.2, 1e-9)
		t.near(sample.temperature, -6.7, 1e-9, "a new room's air is the outside's")
		t.eq(sample.outside, -6.7)
		-- Anywhere in it: the same room, no fill.
		local corner = assert(RoomWorld.sampleIn(fake.rooms, 4.9, G + 2, 0.1))
		t.eq(corner.id, sample.id)
		t.eq(fake.rooms.fills, 1)
		-- Feet in a wall's cell (a slab of planks under them): the head's cell.
		world.set(1, G, 1, B.Planks)
		t.eq((RoomWorld.sampleIn(fake.rooms, 1.5, G, 1.5) :: any).id, sample.id)
		world.set(1, G, 1, B.Air)
		-- The air warms with the player's 1 HU towards its steady value.
		fake.run(400)
		local steady = Rooms.steady(sample, -6.7, 0, HEAT.Player)
		t.near(sample.temperature, steady, 1e-3)
		t.eq(sample.heat, HEAT.Player)
	end)

	t.test("roomworld: at most FillsPerFrame fills and FillMs a frame", function()
		local world = FakeRooms.new(Blocks, Rooms)
		for i = 0, 4 do
			world.house(i * 10, 0, 3, 3, 2, B.Stone)
		end
		local fake = game(world)
		for i = 0, 4 do
			RoomWorld.sampleIn(fake.rooms, i * 10 + 1, G, 1)
		end
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(fake.rooms.fills, SETTINGS.FillsPerFrame, "the frame's fills")
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(fake.rooms.fills, 5)
		t.eq(fake.rooms.count, 5)
		-- A slow fill uses the frame's time up.
		local slow = game(world)
		local getBlock = world.getBlock
		slow.env.getBlock = function(x: number, y: number, z: number): number?
			slow.now += 0.0001
			return getBlock(x, y, z)
		end
		for i = 0, 4 do
			RoomWorld.sampleIn(slow.rooms, i * 10 + 1, G, 1)
		end
		RoomWorld.stepWorld(slow.rooms, 1 / 60)
		t.eq(slow.rooms.fills, 1, "past FillMs after one")
		t.ok(slow.rooms.longestMs >= SETTINGS.FillMs, "its time measured")
	end)

	t.test("roomworld: block changes refill what they touch, the air kept", function()
		local world = plankHouse()
		local fake = game(world, sourced(B.Campfire, campfire))
		fake.players = { { 2.5, G, 2.5 } }
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		fake.run(1, 1)
		change(fake, world, 3, G, 3, B.Campfire)
		fake.run(1, 1)
		local first = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		t.eq(#fake.rooms.rooms[first.id].room.sources, 1, "the campfire found by its refill")
		fake.run(200)
		local warm = first.temperature
		t.ok(warm > 0, `warmed {warm}`)
		local fills = fake.rooms.fills
		-- A torch put down changes nothing.
		change(fake, world, 1, G, 1, B.Torch)
		fake.run(1, 1)
		t.eq(fake.rooms.fills, fills, "no refill")
		t.eq((RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5) :: any).id, first.id)
		warm = first.temperature
		-- The door opened (a block change at its walls): filled again, the doorway's air at the
		-- outside's, the rest kept.
		change(fake, world, 2, G, -1, B.OakDoorOpen)
		change(fake, world, 2, G + 1, -1, B.OakDoorOpenTop)
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(fake.rooms.fills, fills + 1, "one refill for both halves")
		local opened = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		t.ok(opened.id ~= first.id)
		t.eq(opened.volume, 77)
		t.near(opened.temperature, (75 * warm + 2 * -6.7) / 77, 1e-9, "volume-weighted")
		t.eq(fake.rooms.rooms[first.id], nil, "the old room is gone")
		t.eq(fake.rooms.count, 1)
		-- A wall built across: both halves keep the air.
		local before = opened.temperature
		change(fake, world, 2, G, 2, B.Planks)
		for z = 0, 4 do
			for y = G, G + 2 do
				if world.get(2, y, z) ~= B.Planks then
					change(fake, world, 2, y, z, B.Planks)
				end
			end
		end
		for _ = 1, 6 do
			RoomWorld.stepWorld(fake.rooms, 1 / 60)
		end
		local left = assert(RoomWorld.sampleIn(fake.rooms, 0.5, G, 2.5))
		local right = assert(RoomWorld.sampleIn(fake.rooms, 4.5, G, 2.5))
		t.ok(left.id ~= right.id, "two rooms")
		t.near(left.temperature, before, 1e-9, "the left half's air")
		t.near(right.temperature, before, 1e-9, "the right half's air")
		t.eq(left.volume + right.volume, 77 - 15 - 2, "the wall took 15 cells, the doorway is cut off")
		-- (The doorway's two cells, under the roof's edge with their two open faces, are a nook of
		-- their own, with the air they had.)
		local nook = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, -0.5))
		t.eq(nook.volume, 2)
		t.near(nook.temperature, before, 1e-9)
		t.eq(fake.rooms.count, 3)
		-- Knocked through again after the halves drifted apart: the volume-weighted mean.
		fake.run(30)
		local tl, tr, vl, vr = left.temperature, right.temperature, left.volume, right.volume
		local tn = nook.temperature
		t.ok(math.abs(tl - tr) > 0.1, "the campfire's half is warmer")
		for z = 0, 4 do
			for y = G, G + 2 do
				change(fake, world, 2, y, z, B.Air)
			end
		end
		for _ = 1, 4 do
			RoomWorld.stepWorld(fake.rooms, 1 / 60)
		end
		local merged = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		t.eq(merged.volume, 77)
		t.near(
			merged.temperature,
			(tl * vl + tr * vr + tn * 2 + 15 * -6.7) / 77,
			1e-9,
			"the halves' and the nook's air, the wall's cells new"
		)
		t.eq(fake.rooms.count, 1)
	end)

	t.test("roomworld: an open space is no room for NotRoomSeconds, unless a block there changes", function()
		local world = plankHouse()
		local fake = game(world)
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		fake.run(1, 1)
		t.ok(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5) ~= nil)
		-- The back wall knocked out: refilled, open, no room.
		for x = 0, 4 do
			change(fake, world, x, G + 1, 5, B.Air)
		end
		change(fake, world, -1, G + 1, 1, B.Air)
		change(fake, world, -1, G + 1, 3, B.Air)
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5), nil, "open now")
		t.eq(fake.rooms.count, 0)
		local fills = fake.rooms.fills
		-- Players walking about in it start no fills for a while.
		for _ = 1, 4 do
			for x = 0, 4 do
				RoomWorld.sampleIn(fake.rooms, x + 0.5, G, 1.5)
			end
			RoomWorld.stepWorld(fake.rooms, 1)
		end
		t.eq(fake.rooms.fills, fills, "remembered as no room")
		fake.run(2)
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(fake.rooms.fills, fills + 1, "looked at again after NotRoomSeconds")
		-- Walled up again: a change in the space looks again at once.
		local now = fake.rooms.fills
		for x = 0, 4 do
			change(fake, world, x, G + 1, 5, B.Planks)
		end
		change(fake, world, -1, G + 1, 1, B.Planks)
		change(fake, world, -1, G + 1, 3, B.Planks)
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(fake.rooms.fills, now + 1)
		t.ok(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5) ~= nil, "a room again")
		-- Outdoors under the sky: no room, cheaply.
		t.eq(RoomWorld.sampleIn(fake.rooms, 50.5, G, 50.5), nil)
		RoomWorld.stepWorld(fake.rooms, 1 / 60)
		t.eq(RoomWorld.sampleIn(fake.rooms, 50.5, G, 50.5), nil)
	end)

	t.test("roomworld: rooms nobody visits are forgotten unless a source lives in them", function()
		local world = plankHouse()
		world.house(20, 0, 3, 3, 2, B.Stone)
		local burning = true
		world.set(21, G, 1, B.Campfire)
		local function fire(): number
			return if burning then HEAT.Campfire else 0
		end
		local fake = game(world, sourced(B.Campfire, fire))
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		RoomWorld.sampleIn(fake.rooms, 20.5, G, 0.5)
		fake.run(1, 1)
		t.eq(fake.rooms.count, 2)
		fake.run(SETTINGS.ForgetSeconds + 2)
		t.eq(fake.rooms.count, 1, "the empty house is forgotten")
		t.ok(RoomWorld.temperatureIn(fake.rooms, 20, G, 0) ~= nil, "the campfire's room is kept")
		burning = false
		fake.run(2)
		t.eq(fake.rooms.count, 0, "once its fire is out")
		-- A player inside keeps it.
		fake.players = { { 2.5, G, 2.5 } }
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		fake.run(SETTINGS.ForgetSeconds + 5)
		t.eq(fake.rooms.count, 1)
	end)

	t.test("roomworld: machines seed rooms near players; climateAt sums the heat for the call", function()
		local world = plankHouse()
		world.set(4, G, 4, B.ElectricHeater)
		local output = 0
		local function heater(): number
			return output
		end
		local fake = game(world, sourced(B.ElectricHeater, heater))
		local sample, outside = RoomWorld.climateIn(fake.rooms, 4, G, 4)
		t.eq(sample, nil, "no room known")
		t.eq(outside, -6.7, "the outdoor value")
		fake.run(SETTINGS.MachineSeedSeconds + 1)
		t.eq(fake.rooms.fills, 0, "nobody within Range")
		fake.players = { { 4 + SETTINGS.Range + 10, G, 4 } }
		fake.run(SETTINGS.MachineSeedSeconds + 1)
		t.eq(fake.rooms.fills, 0, "still too far")
		fake.players = { { 4 + SETTINGS.Range - 10, G, 4 } }
		fake.run(SETTINGS.MachineSeedSeconds + 1)
		t.ok(fake.rooms.fills >= 1)
		local room = assert((RoomWorld.climateIn(fake.rooms, 4, G, 4)))
		t.eq(room.volume, 74, "the heater stands in a corner")
		local id = room.id
		output = 12.5
		local now = assert((RoomWorld.climateIn(fake.rooms, 4, G, 4)))
		t.eq(now.heat, 12.5, "summed at the call")
		t.eq(now.id, id)
		-- A machine in a wall between the room and the outside finds the room too.
		world.set(5, G, 2, B.ElectricHeater)
		t.eq((RoomWorld.climateIn(fake.rooms, 5, G, 2) :: any).id, id)
		-- Outdoors: none, and the outside value (kept a second per machine).
		local none, out = RoomWorld.climateIn(fake.rooms, 40, G, 40)
		t.eq(none, nil)
		t.eq(out, -6.7)
		-- Placing a campfire somewhere seeds there (a room source block), breaking it forgets it.
		local campfires = FakeRooms.new(Blocks, Rooms)
		campfires.house(0, 0, 3, 3, 2, B.Stone)
		local seeded = game(campfires, sourced(B.Campfire, campfire))
		seeded.players = { { 50, G, 50 } }
		change(seeded, campfires, 1, G, 1, B.Campfire)
		seeded.run(SETTINGS.MachineSeedSeconds + 1)
		t.eq(seeded.rooms.count, 1, "a campfire's room")
		t.near(RoomWorld.temperatureIn(seeded.rooms, 1, G + 1, 1) :: number, -6.7, 20, "followed")
	end)

	t.test("roomworld: temperatureAt in cells and walls; sources' limits; players near", function()
		local world = plankHouse()
		world.house(30, 0, 3, 3, 2, B.Stone)
		for x = 30, 32 do
			world.set(x, G, 1, B.Fire)
		end
		world.set(31, G, 0, B.Fire)
		world.set(31, G, 2, B.Fire)
		local function fire(): number
			return HEAT.Fire
		end
		local fake = game(world, sourced(B.Fire, fire, HEAT.FireMax))
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		RoomWorld.sampleIn(fake.rooms, 30.5, G, 2.5)
		fake.run(2, 1)
		local fires = assert(RoomWorld.sampleIn(fake.rooms, 30.5, G, 2.5))
		t.eq(fires.heat, HEAT.Fire * HEAT.FireMax, "five fires, three counted")
		local cell = RoomWorld.temperatureIn(fake.rooms, 2, G + 1, 2)
		t.ok(cell ~= nil, "a cell")
		t.eq(RoomWorld.temperatureIn(fake.rooms, 2, G + 3, 2), cell, "the roof over it")
		t.eq(RoomWorld.temperatureIn(fake.rooms, 2, G + 4, 2), nil, "above the roof")
		t.eq(RoomWorld.temperatureIn(fake.rooms, 60, G, 60), nil, "outdoors")
		t.eq(RoomWorld.temperatureIn(fake.rooms, 4, G + 3, 0), cell, "a roof block at its corner")
		t.eq(RoomWorld.temperatureIn(fake.rooms, -1, G + 1, 2), cell, "a wall")
		t.eq(RoomWorld.temperatureIn(fake.rooms, 2, G - 1, 2), cell, "the floor")
		-- A lookup only (Seasons/SnowWorld asks many times a tick): no fill, no queue, nothing made.
		local unknown = FakeRooms.new(Blocks, Rooms)
		unknown.house(0, 0, 3, 3, 2, B.Stone)
		local cold = game(unknown)
		t.eq(RoomWorld.temperatureIn(cold.rooms, 1, G, 1), nil, "a room nobody found yet")
		t.eq(RoomWorld.temperatureIn(cold.rooms, 1, G + 2, 1), nil, "its roof")
		cold.run(SETTINGS.MachineSeedSeconds + 1)
		t.eq(cold.rooms.fills, 0, "never a fill")
		local fills = fake.rooms.fills
		local before = collectgarbage("count")
		for _ = 1, 20000 do
			RoomWorld.temperatureIn(fake.rooms, 2, G + 3, 2)
			RoomWorld.temperatureIn(fake.rooms, 2, G + 1, 2)
			RoomWorld.temperatureIn(fake.rooms, 60, G, 60)
		end
		local grown = collectgarbage("count") - before
		t.ok(grown < 64, `{grown} KB for 60 000 lookups`)
		t.eq(fake.rooms.fills, fills)
		-- Players near a cell (a space heater's standby).
		fake.players = { { 10, G, 10 } }
		fake.run(1, 1)
		t.ok(RoomWorld.nearIn(fake.rooms, 12, G, 10, HEAT.StandbyRadius))
		t.eq(RoomWorld.nearIn(fake.rooms, 40, G, 10, HEAT.StandbyRadius), false)
		-- A wall between two rooms gives the warmer one's air.
		local pair = plankHouse()
		pair.fill(2, G, 0, 2, G + 2, 4, B.Planks)
		pair.set(0, G, 2, B.Campfire)
		local both = game(pair, sourced(B.Campfire, campfire))
		RoomWorld.sampleIn(both.rooms, 0.5, G, 0.5)
		RoomWorld.sampleIn(both.rooms, 4.5, G, 0.5)
		both.run(60)
		local warm = assert(RoomWorld.temperatureIn(both.rooms, 0, G + 1, 0))
		local cool = assert(RoomWorld.temperatureIn(both.rooms, 4, G + 1, 0))
		t.ok(warm > cool + 1, `the campfire's side {warm}, the other {cool}`)
		t.eq(RoomWorld.temperatureIn(both.rooms, 2, G + 1, 1), warm, "the wall between")
		t.eq(RoomWorld.temperatureIn(both.rooms, 5, G + 1, 1), cool, "an outer wall of the cool one")
	end)

	t.test("roomworld: the eaves over a warm house's walls answer temperatureAt (snow on them melts)", function()
		local world = plankHouse()
		world.set(1, G, 1, B.Campfire)
		world.set(3, G, 3, B.Campfire)
		local fake = game(world, sourced(B.Campfire, campfire))
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		fake.run(300)
		local sample = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		local air = sample.temperature
		t.ok(air >= Config.Seasons.Snow.RoomMelt, `warm enough to melt snow: {air}`)
		-- The roof over the walls' tops, the corners too: the house's air (Seasons/SnowWorld asks
		-- for the snow's cell and the block under it).
		local eaves = 0
		for x = -1, 5 do
			for z = -1, 5 do
				if x == -1 or x == 5 or z == -1 or z == 5 then
					t.eq(RoomWorld.temperatureIn(fake.rooms, x, G + 3, z), air, `the eave over ({x}, {z})`)
					t.eq(RoomWorld.temperatureIn(fake.rooms, x, G + 4, z), nil, "the snow's cell over it")
					eaves += 1
				end
			end
		end
		t.eq(eaves, 24)
		t.eq(RoomWorld.temperatureIn(fake.rooms, -2, G + 3, 2), nil, "past the eaves")
		-- For the lookup only: the house loses what it did.
		t.near(sample.uaOut, 83 * 0.025 + 0.2, 1e-9)
	end)

	t.test("roomworld: a source in a wall between two rooms heats one, the room it measures", function()
		-- Two 2 x 5 x 3 rooms of a plank house split by a plank wall at x = 2, a Wood Stove in it.
		local function split(block: number): any
			local world = FakeRooms.new(Blocks, Rooms)
			world.house(0, 0, 5, 5, 3, B.Planks)
			world.fill(2, G, 0, 2, G + 2, 4, B.Planks)
			world.set(2, G, 2, block)
			return world
		end
		local world = split(B.WoodStove)
		local fake = game(
			world,
			sourced(B.WoodStove, function(): number
				return HEAT.WoodStove
			end)
		)
		-- (Someone looks into each room every second: the cold one is not forgotten.)
		for _ = 1, 120 do
			RoomWorld.sampleIn(fake.rooms, 0.5, G, 0.5)
			RoomWorld.sampleIn(fake.rooms, 4.5, G, 0.5)
			fake.run(1, 1)
		end
		local west = assert(RoomWorld.sampleIn(fake.rooms, 0.5, G, 0.5))
		local east = assert(RoomWorld.sampleIn(fake.rooms, 4.5, G, 0.5))
		t.ok(west.id ~= east.id, "two rooms")
		t.eq(#fake.rooms.rooms[west.id].room.sources, 1, "the stove walls both")
		t.eq(#fake.rooms.rooms[east.id].room.sources, 1)
		local own = assert((RoomWorld.climateIn(fake.rooms, 2, G, 2)))
		t.eq(own.id, east.id, "the stove's room: the first of its neighbours in one")
		t.eq(east.heat, HEAT.WoodStove, "all of its heat")
		t.eq(west.heat, 0, "none on the other side")
		t.ok(east.temperature > west.temperature + 10, `{east.temperature} and {west.temperature}`)

		-- An Electric Heater there: it holds the room it measures and pays for what that room gets.
		local heaterWorld = split(B.ElectricHeater)
		local container = Machines.newContainer(B.ElectricHeater)
		Machines.set(container, "setPoint", 5)
		local heated = game(
			heaterWorld,
			sourced(B.ElectricHeater, function(): number
				return Machines.get(container, "heat")
			end)
		)
		RoomWorld.sampleIn(heated.rooms, 0.5, G, 0.5)
		RoomWorld.sampleIn(heated.rooms, 4.5, G, 0.5)
		RoomWorld.stepWorld(heated.rooms, 1 / 20)
		local ctx: any = {
			block = B.ElectricHeater,
			x = 2,
			y = G,
			z = 2,
			energy = assert(Machines.energyOf(B.ElectricHeater)),
			tick = 0,
			dayTime = 18000,
			getBlock = heaterWorld.getBlock,
			climate = function(x: number, y: number, z: number): (any, number)
				return RoomWorld.climateIn(heated.rooms, x, y, z)
			end,
		}
		-- (What it paid over the last 40 s, held.)
		local joules, ticks, counted = 0, 200 * 20, 40 * 20
		for tick = 1, ticks do
			ctx.tick += 1
			Machines.set(container, "energy", Machines.capacity(container))
			Machines.tick(container, ctx)
			if tick > ticks - counted then
				joules += -Machines.view(container).rate
			end
			RoomWorld.stepWorld(heated.rooms, 1 / 20)
			if tick % 20 == 0 then
				RoomWorld.sampleIn(heated.rooms, 0.5, G, 0.5)
			end
		end
		local cold = assert(RoomWorld.sampleIn(heated.rooms, 0.5, G, 0.5))
		local warm = assert(RoomWorld.sampleIn(heated.rooms, 4.5, G, 0.5))
		local paid = joules / counted / HEAT.HeaterJoules
		t.near(warm.temperature, 5, 0.5, "held at its set point")
		t.eq(cold.heat, 0, "the other room gets none of it")
		t.near(warm.heat, paid, 0.5, `delivered {warm.heat} HU for {paid} HU paid`)
		t.near(warm.heat, Rooms.thermostat(5, 5, warm, warm.outside, 0, 0, HEAT.ElectricHeater), 0.5)
	end)

	t.test("roomworld: two thermostats in one room share it without hunting", function()
		-- The plank house with one Electric Heater in its side wall and one on its floor.
		local world = plankHouse()
		world.set(5, G, 2, B.ElectricHeater)
		world.set(2, G, 2, B.ElectricHeater)
		local a = Machines.newContainer(B.ElectricHeater)
		local b = Machines.newContainer(B.ElectricHeater)
		Machines.set(a, "setPoint", 2)
		Machines.set(b, "setPoint", 2)
		local fake = game(
			world,
			sourced(B.ElectricHeater, function(x: number): number
				return Machines.get(if x == 5 then a else b, "heat")
			end)
		)
		RoomWorld.sampleIn(fake.rooms, 0.5, G, 0.5)
		RoomWorld.stepWorld(fake.rooms, 1 / 20)
		local function context(x: number): any
			return {
				block = B.ElectricHeater,
				x = x,
				y = G,
				z = 2,
				energy = assert(Machines.energyOf(B.ElectricHeater)),
				tick = 0,
				dayTime = 18000,
				getBlock = world.getBlock,
				climate = function(cx: number, cy: number, cz: number): (any, number)
					return RoomWorld.climateIn(fake.rooms, cx, cy, cz)
				end,
			}
		end
		local ca, cb = context(5), context(2)
		local totals: { number } = {}
		for second = 1, 300 do
			for _ = 1, 20 do
				for _, pair in { { a, ca }, { b, cb } } do
					pair[2].tick += 1
					Machines.set(pair[1], "energy", Machines.capacity(pair[1]))
					Machines.tick(pair[1], pair[2])
				end
				RoomWorld.stepWorld(fake.rooms, 1 / 20)
			end
			totals[second] = Machines.get(a, "heat") + Machines.get(b, "heat")
		end
		local room = assert(RoomWorld.sampleIn(fake.rooms, 0.5, G, 0.5))
		t.near(room.temperature, 2, 0.5, "held")
		t.near(room.heat, totals[300], 1e-9, "both count in the room")
		local need = room.uaOut * (2 - room.outside) + room.uaGround * 2
		for second = 240, 300 do
			t.near(totals[second], need, 0.5, "no hunting")
		end
	end)

	t.test("roomworld: a room whose roof is blown off goes at once, leaving one failure", function()
		-- A 16 x 16 x 3 stone hall (768 cells) with a campfire and a player.
		local world = FakeRooms.new(Blocks, Rooms)
		world.house(0, 0, 16, 16, 3, B.Stone)
		world.set(8, G, 8, B.Campfire)
		local fake = game(world, sourced(B.Campfire, campfire))
		fake.players = { { 2.5, G, 2.5 } }
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		fake.run(10, 1 / 60)
		local before = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		t.eq(before.volume, 768)
		-- An explosion takes the whole roof at once.
		for x = -1, 16 do
			for z = -1, 16 do
				change(fake, world, x, G + 3, z, B.Air)
			end
		end
		local fills, frames = fake.rooms.fills, 0
		while fake.rooms.count > 0 and frames < 600 do
			RoomWorld.stepWorld(fake.rooms, 1 / 60)
			frames += 1
		end
		t.eq(frames, 1, "gone in the frame after")
		t.eq(fake.rooms.fills - fills, 1, "one fill")
		t.eq(#fake.rooms.failures, 1, "one failure remembered")
		t.eq(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5), nil, "no warm air answered")
		t.eq(RoomWorld.temperatureIn(fake.rooms, 8, G + 1, 8), nil)
		t.eq(RoomWorld.temperatureIn(fake.rooms, -1, G + 1, 8), nil, "nor in its walls")
	end)

	t.test("roomworld: a burning stove finds its room and keeps it with nobody in the house", function()
		-- A stove restored from a save: its block is there (no change seen), it burns, and the only
		-- player is outside, within Range.
		local world = plankHouse()
		world.set(4, G, 4, B.WoodStove)
		local stove = Machines.newContainer(B.WoodStove)
		stove.slots[1] = Items.newStack(Items.id.Coal, 4)
		local fake = game(
			world,
			sourced(B.WoodStove, function(): number
				return Machines.get(stove, "heat")
			end)
		)
		fake.players = { { 20.5, G, 20.5 } }
		local ctx: any = {
			block = B.WoodStove,
			x = 4,
			y = G,
			z = 4,
			energy = assert(Machines.energyOf(B.WoodStove)),
			tick = 0,
			dayTime = 18000,
			getBlock = world.getBlock,
			climate = function(x: number, y: number, z: number): (any, number)
				return RoomWorld.climateIn(fake.rooms, x, y, z)
			end,
		}
		for _ = 1, 400 * 20 do
			ctx.tick += 1
			Machines.tick(stove, ctx)
			RoomWorld.stepWorld(fake.rooms, 1 / 20)
		end
		local room = assert((RoomWorld.climateIn(fake.rooms, 4, G, 4)), "the stove's room found")
		t.eq(room.heat, HEAT.WoodStove)
		t.near(room.temperature, Rooms.steady(room, -6.7, 0, HEAT.WoodStove), 0.5, "heated")
		t.eq(fake.rooms.count, 1, "kept past ForgetSeconds")
	end)

	t.test("roomworld: before start there are no rooms, and a heater is a space heater", function()
		-- The module's own functions before (without) RoomWorld.start: what Machines/Machines' env
		-- gives the kinds.
		t.eq(RoomWorld.world(), nil, "no rooms world")
		t.eq(RoomWorld.sample(0, G, 0), nil)
		local none, outside = RoomWorld.climateAt(0, G, 0)
		t.eq(none, nil)
		t.eq(outside, 0)
		t.eq(RoomWorld.temperatureAt(0, G, 0), nil)
		t.eq(RoomWorld.playerNear(0, G, 0, HEAT.StandbyRadius), true, "no positions to go by: near")
		local container = Machines.newContainer(B.ElectricHeater)
		local ctx: any = {
			block = B.ElectricHeater,
			x = 0,
			y = G,
			z = 0,
			energy = assert(Machines.energyOf(B.ElectricHeater)),
			tick = 0,
			dayTime = 18000,
			getBlock = function(): number
				return B.Air
			end,
			climate = RoomWorld.climateAt,
			near = RoomWorld.playerNear,
		}
		for _ = 1, 40 do
			ctx.tick += 1
			Machines.set(container, "energy", Machines.capacity(container))
			Machines.tick(container, ctx)
		end
		t.eq(Machines.state(container), HeatStates.HEATING, "never Standby")
		t.eq(Machines.get(container, "heat"), HEAT.SpaceHeater)
	end)

	t.test("roomworld: started with the rooms off, a heater stands by unless a player is near it", function()
		-- RoomWorld loaded afresh (a module state of its own) and started as the server does, with
		-- Config.Seasons.Rooms off and Players/PlayerPositions a stub giving `positions`.
		local positions: { { number } } = {}
		local stub = {
			each = function(): () -> (number?, number, number, number)
				local i = 0
				return function(): (number?, number, number, number)
					i += 1
					local feet = positions[i]
					if feet == nil then
						return nil, 0, 0, 0
					end
					return i, feet[1], feet[2], feet[3]
				end
			end,
		}
		local players =
			{ Name = "Players", PlayerPositions = { Name = "PlayerPositions" }, Climate = server.Players.Climate }
		local script =
			{ Name = "RoomWorld", Parent = { Name = "Seasons", Parent = { Name = "IceVoxel", Players = players } } }
		local game = {
			GetService = function(_, name: string): any
				assert(name == "ReplicatedStorage", `no fake service {name}`)
				return shared.Parent
			end,
		}
		local fresh = luau.load(withHeader(fs.readFile(SOURCE)), { debugName = SOURCE })(
			script,
			function(node: any): any
				return if node == players.PlayerPositions then stub else require(node)
			end,
			game
		)
		local settings = Config.Seasons.Rooms
		local enabled = settings.Enabled
		settings.Enabled = false
		local ok, err = pcall(fresh.start, {})
		settings.Enabled = enabled
		assert(ok, err)
		t.eq(fresh.world(), nil, "no rooms")
		local container = Machines.newContainer(B.ElectricHeater)
		local ctx: any = {
			block = B.ElectricHeater,
			x = 0,
			y = G,
			z = 0,
			energy = assert(Machines.energyOf(B.ElectricHeater)),
			tick = 0,
			dayTime = 18000,
			getBlock = function(): number
				return B.Air
			end,
			climate = fresh.climateAt,
			near = fresh.playerNear,
		}
		local function run()
			for _ = 1, 40 do
				ctx.tick += 1
				Machines.set(container, "energy", Machines.capacity(container))
				Machines.tick(container, ctx)
			end
		end
		-- Nobody on the server, then one player past StandbyRadius: it stands by, drawing nothing.
		run()
		t.eq(Machines.state(container), HeatStates.STANDBY, "nobody near")
		t.eq(Machines.get(container, "heat"), 0)
		positions[1] = { HEAT.StandbyRadius + 4.5, G, 0.5 }
		run()
		t.eq(Machines.state(container), HeatStates.STANDBY, "a player far off")
		-- One beside it: the space heater.
		positions[2] = { 2.5, G, 0.5 }
		run()
		t.eq(Machines.state(container), HeatStates.HEATING, "a player beside it")
		t.eq(Machines.get(container, "heat"), HEAT.SpaceHeater)
		positions[2] = nil
		run()
		t.eq(Machines.state(container), HeatStates.STANDBY, "gone again")
	end)

	t.test("roomworld: the sheltered outside value (Tough As Nails under a roof), within OutsideLimit", function()
		local plains = Biomes.get(PLAINS)
		for _, dayTime in { 6000, 18000 } do
			local value = RoomWorld.outsideValue(70, 70, PLAINS, dayTime, 1)
			local env: any = {
				climate = plains.temperature,
				y = 70,
				surface = 70,
				skyOpen = false,
				night = not DayCycle.isDay(dayTime),
				wet = false,
				sprinting = false,
				heated = false,
				nearHeat = false,
				cooled = false,
				burning = false,
				armorWarmth = 0,
				armorCooling = 0,
			}
			t.near(value, Temperature.outside(env), 1e-12, `at {dayTime}`)
		end
		-- Underground: the middle of NEUTRAL.
		t.near(RoomWorld.outsideValue(20, 70, PLAINS, 18000, 1), 0, 1e-9)
		-- Rooms use it without an `outside` of the test's.
		local world = plankHouse()
		local fake = game(world, { climate = true })
		RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		fake.run(1, 1)
		local sample = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		t.near(sample.outside, RoomWorld.outsideValue(G, G, PLAINS, 18000, 7), 1e-12)
		t.ok(math.abs(sample.outside) <= SETTINGS.OutsideLimit)
	end)

	t.test("roomworld: an electric heater's thermostat holds its room through climateAt", function()
		local world = plankHouse()
		world.set(4, G, 4, B.ElectricHeater)
		local container = Machines.newContainer(B.ElectricHeater)
		Machines.set(container, "setPoint", 2)
		local function heat(): number
			return Machines.get(container, "heat")
		end
		local fake = game(world, sourced(B.ElectricHeater, heat))
		fake.players = { { 2.5, G, 2.5 } }
		local ctx: any = {
			block = B.ElectricHeater,
			x = 4,
			y = G,
			z = 4,
			energy = assert(Machines.energyOf(B.ElectricHeater)),
			tick = 0,
			dayTime = 18000,
			getBlock = world.getBlock,
			climate = function(x: number, y: number, z: number): (any, number)
				return RoomWorld.climateIn(fake.rooms, x, y, z)
			end,
			near = function(): boolean
				return true
			end,
		}
		local most = 0
		for _ = 1, 400 * 20 do
			ctx.tick += 1
			Machines.set(container, "energy", Machines.capacity(container))
			Machines.tick(container, ctx)
			most = math.max(most, Machines.get(container, "heat"))
			RoomWorld.stepWorld(fake.rooms, 1 / 20)
			RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5)
		end
		local sample = assert(RoomWorld.sampleIn(fake.rooms, 2.5, G, 2.5))
		t.ok(math.abs(sample.temperature - 2) <= 0.5, `held at {sample.temperature}`)
		t.ok(most <= HEAT.ElectricHeater, "never above its most")
		t.eq(Machines.state(container), HeatStates.AT_SET_POINT)
		local need = sample.uaOut * (2 + 6.7) + sample.uaGround * 2 - HEAT.Player
		t.near(Machines.get(container, "heat"), need, 0.5, "what holding it takes")
		t.near(
			-Machines.view(container).rate,
			Machines.get(container, "heat") * HEAT.HeaterJoules,
			0.01,
			"4 J/t per HU"
		)
	end)

	t.test("roomworld: a fill's cost (MaxVolume cells)", function()
		-- A 32 x 32 x 1 hall of stone, read from a buffer as WorldServer.peekBlock reads a chunk:
		-- the most a fill does (1 024 cells, every face read, a sky height per column).
		local SIZE, HEIGHT = 40, 8
		local grid = buffer.create(SIZE * SIZE * HEIGHT * 2)
		local function index(x: number, y: number, z: number): number
			return ((y * SIZE + z) * SIZE + x) * 2
		end
		for x = 0, SIZE - 1 do
			for z = 0, SIZE - 1 do
				buffer.writeu16(grid, index(x, 0, z), B.Dirt)
				buffer.writeu16(grid, index(x, 1, z), B.Grass)
				for y = 2, 4 do
					local inside = x >= 4 and x < 36 and z >= 4 and z < 36 and y == 2
					local hall = x >= 3 and x < 37 and z >= 3 and z < 37
					buffer.writeu16(grid, index(x, y, z), if hall and not inside then B.Stone else B.Air)
				end
			end
		end
		local view: Rooms.View = {
			getBlock = function(x: number, y: number, z: number): number?
				if x < 0 or x >= SIZE or z < 0 or z >= SIZE or y < 0 or y >= HEIGHT then
					return nil
				end
				return buffer.readu16(grid, index(x, y, z))
			end,
			skyAbove = function(x: number, z: number): number
				for y = HEIGHT - 1, 0, -1 do
					if not Rooms.passable(buffer.readu16(grid, index(x, y, z))) then
						return y + 1
					end
				end
				return 0
			end,
		}
		local runs = 20
		local start = os.clock()
		for _ = 1, runs do
			local room = assert(Rooms.fill(view, 10, 2, 10))
			t.eq(room.volume, 1024)
		end
		local ms = (os.clock() - start) * 1000 / runs
		print(`    (a 1 024 cell fill: {string.format("%.2f", ms)} ms)`)
		t.ok(ms < 20, "about a millisecond (generous under load)")
	end)
end

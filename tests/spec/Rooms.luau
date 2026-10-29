--[[
	The seasons' rooms (Shared/Seasons/Rooms), pure over a fake world (tests/lib/FakeRooms): the
	flood fill of sealed rooms, open doors, porches, igloos, leaking, open, too big and unloaded
	spaces, a hole in the roof (one opening, as in a wall; a roofless house and a pit no room), an
	open shaft down to a cellar or a mine (one opening at its foot, however deep), a fill's block
	reads (about six a cell, the walks through what stands inside within its budget), per-face U
	values, the ground's faces, furniture and pillars (no loss), cables through a wall (shut), the
	eaves, heat sources in the cells and the walls; the design's worked numbers (a 5 x 5 x 3 plank
	house in a winter night, a taiga, a desert room); the air's exact exponential and its time
	constant; the thermostat never above its maximum and settling within half a step, alone,
	beside a campfire, two in one room, and a cooler.
]]

local FakeRooms = require("../lib/FakeRooms")

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Rooms = require(shared.Seasons.Rooms)
	local Temperature = require(shared.ToughAsNails.Temperature)

	local B = Blocks.id
	local G = FakeRooms.GROUND
	local HEAT = Config.Seasons.Heat
	-- (A block's room heat is its entry's `roomHeat`.)
	local function roomHeat(name: string): { hu: number, most: number? }
		return (assert(require(shared.Content).default.block(name)) :: any).roomHeat
	end
	local CAMPFIRE_HU = roomHeat("Campfire").hu

	-- The design's house: 5 x 5 x 3 planks on grass, a closed oak door in the front wall and a glass
	-- window in each side wall. Returns the world and the interior's corner.
	local function plankHouse(wall: number?): (any, number, number)
		local world = FakeRooms.new(Blocks, Rooms)
		local front = world.house(0, 0, 5, 5, 3, wall or B.Planks)
		world.set(2, G, front, B.OakDoor)
		world.set(2, G + 1, front, B.OakDoorTop)
		world.set(-1, G + 1, 2, B.Glass)
		world.set(5, G + 1, 2, B.Glass)
		return world, 0, 0
	end

	local function fill(world: any, x: number, y: number, z: number, source: any?): (any, string?)
		return Rooms.fill(world.view(source), x, y, z)
	end

	t.test("rooms: a sealed plank house is a room, its faces' U summed", function()
		local world = plankHouse()
		local room, why = fill(world, 2, G, 2)
		assert(room, why)
		t.eq(room.volume, 75, "5 x 5 x 3")
		t.near(room.uaOut, 81 * 0.025 + 2 * 0.1 + 2 * 0.12, 1e-9, "81 plank faces, the door's two, two windows")
		t.near(room.uaGround, 25 * 0.02, 1e-9, "the floor on grass over dirt: the ground")
		t.eq(room.openings, 0)
		t.eq(#room.sources, 0, "no view of sources: none")
		t.eq(room.minX, 0)
		t.eq(room.maxX, 4)
		t.eq(room.minY, G)
		t.eq(room.maxY, G + 2)
		t.ok(room.walls[Coords.posKey(2, G, -1)], "the door is a wall")
		t.ok(room.walls[Coords.posKey(2, G + 3, 2)], "the roof")
		t.ok(room.walls[Coords.posKey(2, G - 1, 2)], "the floor")
		t.ok(room.cells[Coords.posKey(4, G + 2, 4)], "a far corner")
		t.eq(room.cells[Coords.posKey(2, G + 3, 2)], nil, "not the roof")
		-- The eaves (the roof over the walls' tops, the corners too) are walls for the snow's lookup
		-- (server RoomWorld.temperatureAt), without U: uaOut above has none of them.
		local eaves = 0
		for x = -1, 5 do
			for z = -1, 5 do
				if x == -1 or x == 5 or z == -1 or z == 5 then
					t.ok(room.walls[Coords.posKey(x, G + 3, z)], `the eave over ({x}, {z})`)
					eaves += 1
				end
			end
		end
		t.eq(eaves, 24)
		t.eq(room.walls[Coords.posKey(-1, G + 4, 2)], nil, "nothing over the eaves")
		t.eq(room.walls[Coords.posKey(-1, G + 2, -1)], nil, "nor the corner of the walls under one")
		-- Every interior cell is the same room, whichever it is filled from.
		local again = assert(fill(world, 4, G + 2, 0))
		t.eq(again.volume, 75)
		t.near(again.uaOut, room.uaOut, 1e-9)
		-- A wall's or the sky's cell is no room.
		t.eq(select(2, fill(world, -1, G, 0)), Rooms.OPEN, "seeded in a wall")
		t.eq(select(2, fill(world, 30, G, 30)), Rooms.OPEN, "seeded under the sky")
		-- A floor over air loses to the outside, not the ground.
		local stilts = FakeRooms.new(Blocks, Rooms)
		stilts.house(0, 0, 3, 3, 2, B.Planks)
		stilts.fill(-1, G - 3, -1, 3, G - 2, 3, B.Air)
		stilts.fill(-1, G - 1, -1, 3, G - 1, 3, B.Planks)
		local raised = assert(fill(stilts, 1, G, 1))
		t.eq(raised.uaGround, 0, "nothing solid under the floor")
		t.near(raised.uaOut, (4 * 3 * 2 + 9 + 9) * 0.025, 1e-9)
	end)

	t.test("rooms: the design's worked numbers (a winter night, a taiga, a desert)", function()
		local room = assert(fill(plankHouse(), 2, G, 2))
		local ua = room.uaOut + room.uaGround
		local tau = Rooms.HEAT_CAPACITY * room.volume / ua
		t.near(tau, 50.6, 0.1, "tau = C / UA")
		-- Plains, winter night (outside -6.7, the sheltered value).
		local cold = Rooms.steady(room, -6.7, Rooms.GROUND, 0)
		t.near(cold, -5.57, 0.01, "unheated")
		t.eq(Temperature.zone(math.floor(cold + 0.5)), Temperature.COLD, "-6: COLD")
		local campfire = Rooms.steady(room, -6.7, Rooms.GROUND, CAMPFIRE_HU)
		t.near(campfire, 1.17, 0.01, "a campfire")
		t.eq(Temperature.zone(math.floor(campfire + 0.5)), Temperature.NEUTRAL)
		local heater = Rooms.thermostat(1, 1, room, -6.7, Rooms.GROUND, 0, HEAT.ElectricHeater)
		t.near(heater, 19.5, 0.05, "an electric heater holding +1")
		t.near(heater * HEAT.HeaterJoules, 78, 0.2, "J/t")
		t.near(Rooms.steady(room, -6.7, Rooms.GROUND, heater), 1, 1e-9, "which holds it exactly")
		-- A winter night (its night share 0.55 of a day of 24 000 ticks) on it: about 1 MJ.
		t.near(heater * HEAT.HeaterJoules * 24000 * 0.55 / 1e6, 1.03, 0.01, "MJ a winter night")
		-- Taiga, winter night (-14.2).
		t.near(Rooms.steady(room, -14.2, Rooms.GROUND, 0), -11.8, 0.05, "unheated: ICY")
		t.near(Rooms.steady(room, -14.2, Rooms.GROUND, CAMPFIRE_HU), -5.06, 0.01, "a campfire: COLD")
		t.near(Rooms.thermostat(1, 1, room, -14.2, Rooms.GROUND, 0, 40), 38.0, 0.05, "nearly the heater's most")
		local insulated = assert(fill(plankHouse(B.InsulatedPlanks), 2, G, 2))
		t.near(insulated.uaOut, 81 * 0.006 + 0.2 + 0.24, 1e-9)
		t.near(Rooms.thermostat(1, 1, insulated, -14.2, Rooms.GROUND, 0, 40), 14.6, 0.05, "insulation pays")
		-- The door left open: its two faces open, the losses about double.
		local open = plankHouse()
		open.set(2, G, -1, B.OakDoorOpen)
		open.set(2, G + 1, -1, B.OakDoorOpenTop)
		local leaky = assert(fill(open, 2, G, 2))
		t.eq(leaky.openings, 2, "the doorway's two faces")
		t.eq(leaky.volume, 77, "the doorway's cells are under the roof")
		local ratio = (leaky.uaOut + leaky.uaGround) / ua
		t.ok(ratio > 1.6 and ratio < 1.8, `losses {ratio} x`)
		-- Desert summer noon (+10.4), a 7 x 7 x 3 stone room with a door and two windows.
		local desert = FakeRooms.new(Blocks, Rooms)
		local front = desert.house(0, 0, 7, 7, 3, B.Stone)
		desert.set(3, G, front, B.OakDoor)
		desert.set(3, G + 1, front, B.OakDoorTop)
		desert.set(-1, G + 1, 3, B.Glass)
		desert.set(7, G + 1, 3, B.Glass)
		local hot = assert(fill(desert, 3, G, 3))
		t.near(hot.uaOut, 129 * 0.02 + 0.2 + 0.24, 1e-9)
		t.near(Rooms.steady(hot, 10.4, Rooms.GROUND, 0), 7.85, 0.01, "unheated: 8, HOT")
		t.eq(Temperature.zone(math.floor(Rooms.steady(hot, 10.4, Rooms.GROUND, 0) + 0.5)), Temperature.HOT)
		-- The AC holding 0 with a player inside (1 HU): about -32 HU, 160 J/t.
		local ac = Rooms.thermostat(0, 0, hot, 10.4, Rooms.GROUND, HEAT.Player, HEAT.AirConditioner)
		t.near(ac, -32.4, 0.05, "AC at 0")
		t.near(-ac * HEAT.CoolerJoules, 162, 0.5, "J/t")
	end)

	t.test("rooms: leaks, porches, igloos; open, too big and unloaded spaces give up", function()
		-- Three broken windows: still a room, three openings.
		local leaking = plankHouse()
		leaking.set(1, G + 1, 5, B.Air)
		leaking.set(3, G + 1, 5, B.Air)
		leaking.set(-1, G + 2, 1, B.Air)
		local room = assert(fill(leaking, 2, G, 2))
		t.eq(room.openings, 3)
		t.eq(room.volume, 78, "the window holes are under the roof's edge")
		-- Seven: a pavilion, no room (Config MaxOpenings 6).
		local airy = plankHouse()
		for x = 0, 4 do
			airy.set(x, G + 1, 5, B.Air)
		end
		airy.set(-1, G + 1, 1, B.Air)
		airy.set(-1, G + 1, 3, B.Air)
		local none, why = fill(airy, 2, G, 2)
		t.eq(none, nil)
		t.eq(why, Rooms.OPEN)
		-- A porch: the doorway opens under a roof three wide and two deep, walled at its sides,
		-- its front a wall with a doorway: the fill runs on to where the sky starts.
		local porch = plankHouse()
		porch.set(2, G, -1, B.OakDoorOpen)
		porch.set(2, G + 1, -1, B.OakDoorOpenTop)
		porch.fill(0, G, -4, 4, G + 2, -4, B.Planks)
		porch.fill(0, G, -3, 0, G + 2, -2, B.Planks)
		porch.fill(4, G, -3, 4, G + 2, -2, B.Planks)
		porch.fill(0, G + 3, -4, 4, G + 3, -2, B.Planks)
		porch.set(2, G, -4, B.Air)
		porch.set(2, G + 1, -4, B.Air)
		local covered = assert(fill(porch, 2, G, 2))
		t.eq(covered.volume, 75 + 2 + 3 * 2 * 3 + 2, "the house, its doorway, the porch, the porch's doorway")
		t.eq(covered.openings, 2, "only where the sky starts")
		t.ok(covered.cells[Coords.posKey(2, G, -3)], "the porch is the room's")
		-- The porch's front open wide: no room.
		porch.fill(1, G, -4, 3, G + 2, -4, B.Air)
		t.eq(select(2, fill(porch, 2, G, 2)), Rooms.OPEN)
		-- An igloo: snow walls and a snow roof (U 0.015), its way in walled up; with a campfire it is
		-- warm in a taiga's winter night.
		local igloo = FakeRooms.new(Blocks, Rooms)
		igloo.house(20, 20, 3, 3, 2, B.Snow)
		local inside = assert(fill(igloo, 21, G, 21))
		t.near(inside.uaOut, (4 * 3 * 2 + 9) * 0.015, 1e-9)
		t.ok(Rooms.steady(inside, -14.2, Rooms.GROUND, CAMPFIRE_HU) > 2, "igloos work")
		-- Too big: a hall over MaxExtent long, one over MaxVolume cells.
		local long = FakeRooms.new(Blocks, Rooms)
		long.house(-100, 0, 40, 2, 2, B.Stone)
		t.eq(select(2, fill(long, -90, G, 0)), Rooms.TOO_BIG, "40 long")
		local hall = FakeRooms.new(Blocks, Rooms)
		hall.house(-100, -100, 25, 25, 2, B.Stone)
		t.eq(select(2, fill(hall, -90, G, -90)), Rooms.TOO_BIG, "1 250 cells")
		local limits = { maxVolume = 2000, maxExtent = 40, maxOpenings = 6 }
		t.ok(Rooms.fill(hall.view(), -90, G, -90, limits) ~= nil, "within other limits")
		-- A room reaching cells nobody knows: unloaded.
		local edge = FakeRooms.new(Blocks, Rooms)
		edge.house(FakeRooms.LOADED - 2, 0, 5, 3, 2, B.Stone)
		t.eq(select(2, fill(edge, FakeRooms.LOADED - 1, G, 1)), Rooms.UNLOADED)
		-- On failure `fillCells` keeps the passable cells it went through.
		local visited: { [number]: true } = {}
		local failed = Rooms.fillCells(airy.view(), 2, G, 2, nil, visited)
		t.eq(failed, nil)
		local count = 0
		for key in visited do
			local x, y, z = Coords.decodePosKey(key)
			t.ok(Rooms.passable(airy.get(x, y, z)), "a passable cell")
			count += 1
		end
		t.ok(count > 10, `{count} cells`)
	end)

	t.test("rooms: a hole in the roof is one opening, as one in a wall; roofless spaces and pits are none", function()
		local sealed = assert(fill(plankHouse(), 0, G, 0))
		-- One block of the back wall's top row out (under the roof's edge), and one of the roof.
		local wall = plankHouse()
		wall.set(2, G + 2, 5, B.Air)
		local walled = assert(fill(wall, 0, G, 0))
		t.eq(walled.openings, 1)
		local roof = plankHouse()
		roof.set(2, G + 3, 2, B.Air)
		local roofed, why = fill(roof, 0, G, 0)
		assert(roofed, why)
		t.eq(roofed.openings, 1, "the hole's top: one face")
		t.eq(roofed.volume, 76, "the hole's own cell is the room's")
		t.ok(roofed.cells[Coords.posKey(2, G, 2)] and roofed.cells[Coords.posKey(2, G + 3, 2)], "the column under it")
		t.ok(roofed.walls[Coords.posKey(2, G + 4, 2)], "the opening, where the sky starts")
		-- The same losses: the face the block took, its hole's four sides (the wall hole's floor
		-- loses to the ground) and the opening.
		local roofLoss = roofed.uaOut + roofed.uaGround
		t.near(roofLoss, sealed.uaOut + sealed.uaGround - 0.025 + 4 * 0.025 + 1, 1e-9)
		t.near(roofLoss, walled.uaOut + walled.uaGround, 1e-9, "a roof hole costs what a wall hole does")
		-- A seed under the hole finds the room too (a player standing there).
		t.eq((assert(fill(roof, 2, G, 2))).volume, 76)
		-- A chimney a block wide over the hole: one opening, at its top.
		for y = G + 4, G + 5 do
			roof.set(1, y, 2, B.Brick)
			roof.set(3, y, 2, B.Brick)
			roof.set(2, y, 1, B.Brick)
			roof.set(2, y, 3, B.Brick)
		end
		local chimney = assert(fill(roof, 0, G, 0))
		t.eq(chimney.openings, 1)
		t.eq(chimney.volume, 78)
		-- Two blocks: two openings.
		local two = plankHouse()
		two.set(2, G + 3, 2, B.Air)
		two.set(3, G + 3, 2, B.Air)
		t.eq((assert(fill(two, 0, G, 0))).openings, 2)
		-- A hole three wide, and a house with no roof: no room.
		local wide = plankHouse()
		wide.fill(1, G + 3, 1, 3, G + 3, 3, B.Air)
		t.eq(select(2, fill(wide, 0, G, 0)), Rooms.OPEN, "a 3 x 3 hole")
		local roofless = plankHouse()
		roofless.fill(-1, G + 3, -1, 5, G + 3, 5, B.Air)
		t.eq(select(2, fill(roofless, 0, G, 0)), Rooms.OPEN, "no roof")
		t.eq(select(2, fill(roofless, 2, G, 2)), Rooms.OPEN)
		-- A pit dug in the open (walled on all four sides by the ground, nothing over it) is no room,
		-- nor is the end of a trench.
		local pit = FakeRooms.new(Blocks, Rooms)
		pit.fill(10, G - 2, 10, 10, G - 1, 10, B.Air)
		t.eq(select(2, fill(pit, 10, G - 2, 10)), Rooms.OPEN, "a pit")
		pit.fill(20, G - 2, 10, 20, G - 1, 20, B.Air)
		t.eq(select(2, fill(pit, 20, G - 2, 10)), Rooms.OPEN, "a trench's end")
		-- A deeper pit with a tunnel off it under the ground: the tunnel is a room, the pit's top its
		-- one opening.
		pit.fill(30, G - 3, 10, 30, G - 1, 10, B.Air)
		pit.fill(31, G - 3, 10, 33, G - 2, 10, B.Air)
		local tunnel = assert(fill(pit, 32, G - 3, 10))
		t.eq(tunnel.openings, 1)
		t.eq(tunnel.volume, 3 + 6)
		t.ok(tunnel.cells[Coords.posKey(30, G - 1, 10)], "the pit, up to the ground")
		-- A chimney five blocks over the roof: not climbed past the roof's cover (ROOF), the face up
		-- into the hole one opening all the same.
		for y = G + 6, G + 8 do
			roof.set(1, y, 2, B.Brick)
			roof.set(3, y, 2, B.Brick)
			roof.set(2, y, 1, B.Brick)
			roof.set(2, y, 3, B.Brick)
		end
		local tall = assert(fill(roof, 0, G, 0))
		t.eq(tall.openings, 1)
		t.eq(tall.volume, 75)
		t.ok(tall.walls[Coords.posKey(2, G + 3, 2)], "the hole in the roof, its opening")
	end)

	t.test("rooms: an open shaft down to a cellar or a mine is one opening at its foot, however deep", function()
		-- A 5 x 5 x 3 room dug `depth` below the surface (on a mound of dirt where the ground is too
		-- shallow), a 1-wide, 2-high passage west from its middle and an open 1 x 1 shaft (a
		-- ladder's) from the passage's end up to the surface. Returns the world, the room's floor
		-- and the surface.
		local function mine(depth: number): (any, number, number)
			local world = FakeRooms.new(Blocks, Rooms)
			local surface = math.max(G, depth + 10)
			if surface > G then
				world.fill(-10, G, -5, 8, surface - 1, 9, B.Dirt)
			end
			local floor = surface - depth
			world.fill(0, floor, 0, 4, floor + 2, 4, B.Air)
			world.fill(-2, floor, 2, -1, floor + 1, 2, B.Air)
			world.fill(-3, floor, 2, -3, surface - 1, 2, B.Air)
			return world, floor, surface
		end
		for _, depth in { 10, 40, 100 } do
			local world, floor, surface = mine(depth)
			local room, why = fill(world, 2, floor, 2)
			assert(room, `{depth} deep: {why}`)
			-- The shaft's two cells beside the passage are the room's (open to the sky, under the
			-- ground's cover), the face up from them its one opening: not climbed to the surface.
			t.eq(room.volume, 75 + 4 + 2, `{depth} deep`)
			t.eq(room.openings, 1, `{depth} deep`)
			t.ok(room.cells[Coords.posKey(-3, floor + 1, 2)], "the shaft's foot")
			t.ok(room.walls[Coords.posKey(-3, floor + 2, 2)], "the opening up it")
			t.eq(room.maxY, floor + 2, "nothing of the shaft over the room's height")
			-- Seeded at the shaft's foot: the same room; a player up the ladder is outside.
			t.eq((assert(fill(world, -3, floor, 2))).volume, room.volume)
			t.eq(select(2, fill(world, -3, floor + 8, 2)), Rooms.OPEN, "up the ladder")
			-- Another shaft down through its ceiling: the face up into it one more opening.
			world.fill(2, floor + 3, 2, 2, surface - 1, 2, B.Air)
			local both = assert(fill(world, 2, floor, 2))
			t.eq(both.volume, room.volume)
			t.eq(both.openings, 2)
		end
		-- A shaft straight up from the end of a tunnel 40 deep, and one two wide (1 x 2).
		local floor = G - 40
		local above = FakeRooms.new(Blocks, Rooms)
		above.fill(0, floor, 0, 4, floor + 2, 4, B.Air)
		above.fill(-6, floor, 2, -1, floor + 1, 2, B.Air)
		above.fill(-6, floor + 2, 2, -6, G - 1, 2, B.Air)
		local ended = assert(fill(above, 2, floor, 2))
		t.eq(ended.openings, 1)
		t.eq(ended.volume, 75 + 12)
		above.fill(-7, floor, 2, -7, G - 1, 2, B.Air)
		local wide = assert(fill(above, 2, floor, 2))
		-- (The second column has no air under a cover beside it: the two faces into it at the
		-- tunnel's height, and the one up the first.)
		t.eq(wide.openings, 3)
		t.eq(wide.volume, 75 + 12)
	end)

	t.test("rooms: a fill reads about six blocks a cell, the walks through what stands inside in that", function()
		-- Its reads (the view's getBlock) and its sky scans, counted apart.
		local function counted(world: any, x: number, y: number, z: number, limits: any?): (any, number, number)
			local reads, scans = 0, 0
			local view = {
				getBlock = function(bx: number, by: number, bz: number): number?
					reads += 1
					return world.getBlock(bx, by, bz)
				end,
				skyAbove = function(bx: number, bz: number): number
					scans += 1
					return world.skyAbove(bx, bz)
				end,
			}
			return Rooms.fill(view, x, y, z, limits), reads, scans
		end
		local budget = Config.Seasons.Rooms.MaxVolume * 6
		-- The review's: a 1-wide, 16-high L-shaped gallery dug in the ground, arms 31 long (976
		-- cells), and a 2 x 3 L-shaped mine tunnel: every face of one arm looks across the ground
		-- at the other (37 089 and 17 852 reads with the sky scans before; the walk now looks three
		-- blocks on at most, by the room's cells, reading only when it finds the room there).
		local gallery = FakeRooms.new(Blocks, Rooms)
		gallery.fill(0, G - 40, 0, 30, G - 25, 0, B.Air)
		gallery.fill(0, G - 40, 0, 0, G - 25, 30, B.Air)
		local tunnel = FakeRooms.new(Blocks, Rooms)
		tunnel.fill(0, G - 40, 0, 30, G - 38, 1, B.Air)
		tunnel.fill(0, G - 40, 0, 1, G - 38, 30, B.Air)
		for _, case in { { "the gallery", gallery, 976, 61 }, { "the tunnel", tunnel, 360, 120 } } do
			local name, world, volume, columns = case[1], case[2], case[3], case[4]
			local room, reads, scans = counted(world, 0, G - 40, 0)
			assert(room, name)
			t.eq(room.volume, volume, name)
			t.ok(reads <= 6 * volume and reads <= budget, `{name}: {reads} reads`)
			t.eq(scans, columns, `{name}: a sky scan a column`)
		end
		-- A block three thick standing in the room loses nothing (two reads a face).
		local house = FakeRooms.new(Blocks, Rooms)
		house.house(0, 0, 5, 5, 3, B.Planks)
		local bare = assert(fill(house, 0, G, 0))
		house.fill(1, G, 3, 3, G + 2, 3, B.Stone)
		local thick = assert(fill(house, 0, G, 0))
		t.near(thick.uaOut, bare.uaOut - 3 * 0.025, 1e-9, "only the roof faces it took")
		t.near(thick.uaGround, bare.uaGround - 3 * 0.02, 1e-9, "and the floor's")
		-- A maze of 1 x 1 tunnels two blocks apart (1018 cells), every face of each looking across
		-- two blocks at another: those reads would pass the budget with the fill's own, so none is
		-- made (the blocks between lose, as walls), whichever cell it is filled from.
		local maze = FakeRooms.new(Blocks, Rooms)
		local floor = G - 40
		for layer = 0, 5 do
			local y = floor + layer * 3
			for row = 0, 9 do
				local z = row * 3
				maze.fill(0, y, z, 14, y, z, B.Air)
				if row < 9 then
					local x = if row % 2 == 0 then 14 else 0
					maze.fill(x, y, z + 1, x, y, z + 2, B.Air)
				end
			end
			if layer < 5 then
				local x = if layer % 2 == 0 then 14 else 0
				maze.fill(x, y + 1, 27, x, y + 2, 27, B.Air)
			end
		end
		local first = assert((counted(maze, 0, floor, 0)))
		local other = assert((counted(maze, 7, floor + 15, 27)))
		t.eq(first.volume, 1018)
		t.near(other.uaOut, first.uaOut, 1e-9, "the same room from another seed")
		local roomy = { maxVolume = 4096, maxExtent = 32, maxOpenings = 6 }
		local walked = assert((counted(maze, 0, floor, 0, roomy)))
		t.ok(walked.uaOut < first.uaOut / 2, "with a budget for them, the blocks between lose nothing")
	end)

	t.test("rooms: blocks standing inside a room lose nothing to the outside", function()
		local bare = assert(fill(plankHouse(), 0, G, 0))
		local furnished = plankHouse()
		-- The heater itself, two chests, a stack of two, and a stone pillar from the floor to the roof.
		furnished.set(2, G, 2, B.ElectricHeater)
		furnished.set(1, G, 3, B.Chest)
		furnished.set(3, G, 3, B.Chest)
		furnished.set(1, G, 1, B.Chest)
		furnished.set(1, G + 1, 1, B.Chest)
		furnished.fill(3, G, 1, 3, G + 2, 1, B.Stone)
		local room = assert(fill(furnished, 0, G, 0))
		t.eq(room.volume, 75 - 5 - 3)
		t.eq(room.openings, 0)
		-- Their sides face the room's air on both sides: no loss. The pillar takes a roof face.
		t.near(room.uaOut, bare.uaOut - 0.025, 1e-9, "the walls' and the roof's faces only")
		-- What stands on the floor stands in for the floor face it covers (a chest's U, the heater's
		-- 0.05); the pillar's floor face is gone.
		local expected = bare.uaGround + 3 * (0.025 - 0.02) + (0.05 - 0.02) - 0.02
		t.near(room.uaGround, expected, 1e-9)
		-- They are still the room's walls (a change there fills it again).
		t.ok(room.walls[Coords.posKey(2, G, 2)] and room.walls[Coords.posKey(3, G + 1, 1)])
		-- Against an outer wall a block is the wall there (the face it covers, its own U).
		local backed = plankHouse()
		backed.set(2, G, 4, B.Furnace)
		local against = assert(fill(backed, 0, G, 0))
		t.near(against.uaOut, bare.uaOut - 0.025 + 0.02, 1e-9, "the furnace's back: the wall's face, its U")
		t.near(against.uaGround, bare.uaGround, 1e-9, "on the floor: 0.02 for 0.02")
	end)

	t.test("rooms: a cable, pipe or transporter through a wall keeps it shut", function()
		for _, name in
			{
				"BasicUniversalCable",
				"UltimateUniversalCable",
				"BasicMechanicalPipe",
				"UltimateMechanicalPipe",
				"BasicLogisticalTransporter",
				"RestrictiveTransporter",
			}
		do
			t.eq(Blocks.insulation(B[name]), 0.05, `{name}: a wall face, as a machine`)
			t.eq(Rooms.passable(B[name]), false)
		end
		-- The design house with the heater's power brought in through its back wall.
		local world = plankHouse()
		local sealed = assert(fill(world, 2, G, 2))
		world.set(4, G, 5, B.BasicUniversalCable)
		world.set(4, G, 6, B.BasicUniversalCable)
		local cabled = assert(fill(world, 2, G, 2))
		t.eq(cabled.openings, 0, "no hole in the wall")
		t.eq(cabled.volume, 75)
		t.near(cabled.uaOut, sealed.uaOut - 0.025 + 0.05, 1e-9, "a plank face for a cable's")
		t.near(sealed.uaOut, 2.465, 1e-9, "the worked numbers")
	end)

	t.test("rooms: heat sources in the cells and the walls, each once", function()
		local world = plankHouse()
		world.set(2, G, 2, B.Campfire)
		world.set(4, G, 5, B.Furnace)
		world.set(-1, G, 4, B.Lava)
		local function isSource(block: number): boolean
			return block == B.Campfire or block == B.Furnace or block == B.Lava
		end
		local room = assert(fill(world, 1, G, 1, isSource))
		local found: { [number]: boolean } = {}
		for _, key in room.sources do
			t.eq(found[key], nil, "listed once")
			found[key] = true
		end
		t.ok(found[Coords.posKey(2, G, 2)], "the campfire inside")
		t.ok(found[Coords.posKey(4, G, 5)], "the furnace in the back wall")
		t.ok(found[Coords.posKey(-1, G, 4)], "lava in the side wall")
		t.eq(#room.sources, 3)
		-- A campfire's cell is the room's (its air passes); the furnace and lava are walls.
		t.ok(room.cells[Coords.posKey(2, G, 2)])
		t.near(room.uaOut, 79 * 0.025 + 0.05 + 0.02 + 0.2 + 0.24, 1e-9, "lava 0.05, the furnace 0.02")
	end)

	t.test("rooms: the air steps exactly, at any step", function()
		local room = assert(fill(plankHouse(), 2, G, 2))
		local twice = Rooms.step(Rooms.step(-6.7, room, -6.7, 0, 20, 1), room, -6.7, 0, 20, 1)
		t.near(twice, Rooms.step(-6.7, room, -6.7, 0, 20, 2), 1e-12, "two steps of 1 s are one of 2 s")
		local settled = Rooms.steady(room, -6.7, 0, 20)
		t.near(Rooms.step(-6.7, room, -6.7, 0, 20, 1e6), settled, 1e-9, "a long step lands on the steady value")
		local tau = Rooms.HEAT_CAPACITY * room.volume / (room.uaOut + room.uaGround)
		local after = Rooms.step(-6.7, room, -6.7, 0, 20, tau)
		t.near((after + 6.7) / (settled + 6.7), 1 - math.exp(-1), 1e-9, "1 - 1/e of the way in tau")
		local ninetyFive = Rooms.step(-6.7, room, -6.7, 0, 20, 150)
		t.ok((ninetyFive + 6.7) / (settled + 6.7) > 0.94, "95 % in 2.5 minutes")
		t.eq(Rooms.step(3, room, -6.7, 0, 20, 0), 3, "no time, no change")
		-- Any step is stable: never past the steady value.
		for _, dt in { 0.5, 1, 10, 100, 1000 } do
			local value = Rooms.step(-6.7, room, -6.7, 0, 20, dt)
			t.ok(value <= settled + 1e-9 and value >= -6.7, `dt {dt}`)
		end
	end)

	t.test("rooms: the thermostat never passes its maximum and settles within half a step", function()
		local room = assert(fill(plankHouse(), 2, G, 2))
		for temperature = -15, 15 do
			local p = Rooms.thermostat(1, temperature, room, -14.2, 0, 0, 40)
			t.ok(p >= 0 and p <= 40, `heater at {temperature}: {p}`)
			local c = Rooms.thermostat(0, temperature, room, 10.4, 0, 0, -40)
			t.ok(c <= 0 and c >= -40, `cooler at {temperature}: {c}`)
		end
		-- One heater, from the unheated air of a winter night.
		local function settle(outside: number, setPoint: number, others: number, maxHU: number): (number, number)
			local temperature = Rooms.steady(room, outside, 0, others)
			local p = 0
			for _ = 1, 600 do
				p = Rooms.thermostat(setPoint, temperature, room, outside, 0, others, maxHU)
				t.ok(math.abs(p) <= math.abs(maxHU) + 1e-9, "within its maximum")
				temperature = Rooms.step(temperature, room, outside, 0, p + others, 1)
			end
			return temperature, p
		end
		local held, p = settle(-6.7, 1, 0, 40)
		t.ok(math.abs(held - 1) <= 0.5, `held {held}`)
		t.near(p, 19.5, 0.05)
		-- Beside a campfire it gives what is missing (nothing: the fire alone overshoots a little).
		local warm, q = settle(-6.7, 1, 20, 40)
		t.ok(math.abs(warm - 1) <= 0.5 and q == 0, `beside a campfire {warm} {q}`)
		local mild, r = settle(-14.2, 1, 20, 40)
		t.ok(math.abs(mild - 1) <= 0.5, `taiga with a campfire {mild}`)
		t.near(r, 18.0, 0.05, "the rest of the need")
		-- Too little: it gives all it has and the air stays below.
		local short, s = settle(-14.2, 5, 0, 40)
		t.eq(s, 40)
		t.ok(short < 5 - 0.5, `short {short}`)
		-- Two heaters in one room, each seeing the other's output now: they share the need, steadily.
		local temperature = Rooms.steady(room, -6.7, 0, 0)
		local a, b = 0, 0
		local history = {}
		for second = 1, 300 do
			for _ = 1, 20 do
				a = Rooms.thermostat(1, temperature, room, -6.7, 0, b, 40)
				b = Rooms.thermostat(1, temperature, room, -6.7, 0, a, 40)
			end
			temperature = Rooms.step(temperature, room, -6.7, 0, a + b, 1)
			history[second] = a + b
		end
		t.ok(math.abs(temperature - 1) <= 0.5, `two heaters {temperature}`)
		for second = 240, 300 do
			t.near(history[second], 19.48, 0.05, "no hunting")
		end
		-- A cooler holding a desert room at 0.
		local desert = FakeRooms.new(Blocks, Rooms)
		desert.house(0, 0, 7, 7, 3, B.Stone)
		local hot = assert(fill(desert, 3, G, 3))
		local air = Rooms.steady(hot, 10.4, 0, 0)
		local c = 0
		for _ = 1, 600 do
			c = Rooms.thermostat(0, air, hot, 10.4, 0, 0, -40)
			air = Rooms.step(air, hot, 10.4, 0, c, 1)
		end
		t.ok(math.abs(air) <= 0.5, `cooled {air}`)
		t.ok(c < 0 and c >= -40)
	end)

	t.test("rooms: heat units as the status lines write them", function()
		t.eq(Rooms.huText(32.4), "32")
		t.eq(Rooms.huText(19.5), "20", "whole from 10 up")
		t.eq(Rooms.huText(9.5), "9.5")
		t.eq(Rooms.huText(9.94), "9.9")
		t.eq(Rooms.huText(0.04), "0")
		t.eq(Rooms.huText(-10), "10", "a cooler's, without its sign")
		t.eq(Rooms.huText(3), "3")
		t.eq(Rooms.huText(0 / 0), "0")
	end)
end

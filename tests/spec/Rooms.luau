--[[
	The seasons' rooms (Shared/Seasons/Rooms), pure over a fake world (tests/lib/FakeRooms): the
	flood fill of sealed rooms, open doors, porches, igloos, leaking, open, too big and unloaded
	spaces, per-face U values, the ground's faces, heat sources in the cells and the walls; the
	design's worked numbers (a 5 x 5 x 3 plank house in a winter night, a taiga, a desert room); the
	air's exact exponential and its time constant; the thermostat never above its maximum and
	settling within half a step, alone, beside a campfire, two in one room, and a cooler.
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
		local campfire = Rooms.steady(room, -6.7, Rooms.GROUND, HEAT.Campfire)
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
		t.near(Rooms.steady(room, -14.2, Rooms.GROUND, HEAT.Campfire), -5.06, 0.01, "a campfire: COLD")
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
		t.ok(Rooms.steady(inside, -14.2, Rooms.GROUND, HEAT.Campfire) > 2, "igloos work")
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

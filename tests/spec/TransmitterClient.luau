--[[
	The client side of Mekanism's pipes, its pure parts: the boxes drawn around transmitters and in
	tanks (Rendering/TransmitterModel), the side the Configurator picks from the aim, items moving
	along their path, and WAILA's lines for transmitters and tanks (Ui/WailaInfo).
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Hash = require(shared.Util.Hash)
	local Transmitters = require(shared.Transmitters)
	local TransmitterModel = require(client.Rendering.TransmitterModel)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local M = Transmitters.MODES
	local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5

	local function bit(side: number): number
		return bit32.lshift(1, side)
	end

	local function same(a: { number }, b: { number }): boolean
		return #a == #b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
	end

	local function show(box): string
		return `{box.kind} size {box.size[1]},{box.size[2]},{box.size[3]} at {box.offset[1]},{box.offset[2]},{box.offset[3]}`
	end

	-- The boxes of a kind, in order.
	local function ofKind(boxes, kind: string)
		local found = {}
		for _, box in boxes do
			if box.kind == kind then
				table.insert(found, box)
			end
		end
		return found
	end

	-- The box of `kind` with this size and offset, or an error listing what there is.
	local function find(boxes, kind: string, size: { number }, offset: { number }, what: string)
		for _, box in boxes do
			if box.kind == kind and same(box.size, size) and same(box.offset, offset) then
				return box
			end
		end
		local list = {}
		for _, box in boxes do
			table.insert(list, show(box))
		end
		local wanted = `{kind} {size[1]},{size[2]},{size[3]} at {offset[1]},{offset[2]},{offset[3]}`
		error(`{what}: no {wanted} in: {table.concat(list, "; ")}`, 2)
	end

	-- Box extents along each axis: { min, max } x 3.
	local function extents(box): { { number } }
		local out = {}
		for k = 1, 3 do
			out[k] = { box.offset[k] - box.size[k] / 2, box.offset[k] + box.size[k] / 2 }
		end
		return out
	end

	--[[ Arms ]]

	t.test("transmitter client: a lone transmitter draws nothing over its core", function()
		t.eq(#TransmitterModel.transmitterBoxes(B.BasicLogisticalTransporter, 0, 0, 0, 0, 0), 0, "transporter")
		t.eq(#TransmitterModel.transmitterBoxes(B.EliteMechanicalPipe, 0, 0, 0, 0, 0), 0, "pipe")
		t.eq(#TransmitterModel.transmitterBoxes(B.Stone, 0, 0, 0, 63, 0), 0, "not a transmitter")
		t.eq(#TransmitterModel.transmitterBoxes(B.BasicFluidTank, 0, 0, 0, 63, 0), 0, "a tank is no transmitter")
	end)

	t.test("transmitter client: arms run from the core's frame to the cell's face", function()
		local block = B.AdvancedLogisticalTransporter
		local frame = Blocks.get(block).color
		local glass = (Blocks.get(block).shape :: any)[1].color
		-- To a transmitter: glass, then a collar the neighbour's collar meets.
		local east = TransmitterModel.transmitterBoxes(block, 0, 0, 0, bit(EAST), 0)
		t.eq(#east, 2, "glass and collar")
		local tube = find(east, "glass", { 3.5, 6, 6 }, { 5.75, 0, 0 }, "east glass")
		t.ok(same(tube.colour, glass), "the arm's glass is the core's glass colour")
		local collar = find(east, "frame", { 1, 7, 7 }, { 7.5, 0, 0 }, "east collar")
		t.ok(same(collar.colour, frame), "the collar is in the tier's colour")
		-- Into an acceptor: a wider connector plate on the face.
		local north = TransmitterModel.transmitterBoxes(block, 0, 0, 0, 0, bit(NORTH))
		find(north, "glass", { 6, 6, 3.25 }, { 0, 0, -5.625 }, "north glass")
		find(north, "frame", { 10, 10, 1 }, { 0, 0, -7.5 }, "north plate")
		-- Up and down are square across.
		local up = TransmitterModel.transmitterBoxes(block, 0, 0, 0, bit(UP), bit(DOWN))
		find(up, "glass", { 6, 3.5, 6 }, { 0, 5.75, 0 }, "up glass")
		find(up, "frame", { 7, 1, 7 }, { 0, 7.5, 0 }, "up collar")
		find(up, "frame", { 10, 1, 10 }, { 0, -7.5, 0 }, "down plate")
		-- The same geometry as the item icon's arms (BlockList `icon`: glass {3.5, 6, 6} at 5.75,
		-- collar {1, 7, 7} at 7.5).
		local icon = Blocks.get(block).icon :: any
		local core = #(Blocks.get(block).shape :: any)
		t.ok(same(icon[core + 3].size, tube.size) and icon[core + 3].offset[1] == 5.75, "icon arm")
		t.ok(same(icon[core + 4].size, collar.size) and icon[core + 4].offset[1] == 7.5, "icon collar")
	end)

	t.test("transmitter client: every box stays in its cell and arms stay out of the core", function()
		local blocks = { B.BasicLogisticalTransporter, B.RestrictiveTransporter, B.UltimateMechanicalPipe }
		local count = 0
		for _, block in blocks do
			for linked = 0, 63 do
				for accepting = 0, 63, 7 do
					local acceptors = bit32.band(accepting, bit32.bnot(linked))
					-- Every side PULL / PUSH / NONE / NORMAL in turn, colours and fills too.
					local modes = Transmitters.packModes({ M.PULL, M.PUSH, M.NONE, M.NORMAL, M.PULL, M.PUSH })
					for _, fill in { 0, 1, 128, 255 } do
						local boxes = TransmitterModel.transmitterBoxes(block, modes, 5, fill, linked, acceptors)
						for _, box in boxes do
							count += 1
							local e = extents(box)
							for k = 1, 3 do
								t.ok(e[k][1] >= -8 and e[k][2] <= 8, `{show(box)} leaves the cell`)
								t.ok(box.size[k] > 0, `{show(box)} is empty`)
							end
							if box.kind == "glass" or box.kind == "frame" or box.kind == "band" then
								-- Along its arm's axis it starts at the core's frame (4 pixels out).
								local axis, sign = 0, 0
								for k = 1, 3 do
									if math.abs(box.offset[k]) > 1e-9 then
										axis, sign = k, math.sign(box.offset[k])
									end
								end
								t.ok(axis ~= 0, `{show(box)} is not on an arm`)
								local near = if sign > 0 then e[axis][1] else -e[axis][2]
								t.ok(near >= 4 - 1e-9, `{show(box)} reaches into the core`)
							end
						end
					end
				end
			end
		end
		t.ok(count > 1000, "boxes checked")
	end)

	t.test("transmitter client: arms on opposite sides mirror each other", function()
		for side = 0, 5 do
			local a = TransmitterModel.transmitterBoxes(B.EliteLogisticalTransporter, 0, 0, 0, bit(side), 0)
			local b = TransmitterModel.transmitterBoxes(
				B.EliteLogisticalTransporter,
				0,
				0,
				0,
				bit(Transmitters.opposite(side)),
				0
			)
			t.eq(#a, #b, "box count")
			for i = 1, #a do
				t.ok(same(a[i].size, b[i].size), `side {side} box {i} size`)
				for k = 1, 3 do
					t.eq(a[i].offset[k], -b[i].offset[k], `side {side} box {i} offset`)
				end
			end
		end
	end)

	t.test("transmitter client: PULL and PUSH sides on acceptors carry bands, NORMAL ones do not", function()
		local block = B.BasicLogisticalTransporter
		local all = bit32.bnot(0) % 64
		local modes = Transmitters.packModes({ M.NORMAL, M.PUSH, M.PULL, M.NONE, M.PULL, M.NORMAL })
		-- Between transmitters PUSH and PULL act as NORMAL, and Mekanism draws them so.
		t.eq(#ofKind(TransmitterModel.transmitterBoxes(block, modes, 0, 0, all, 0), "band"), 0, "to transmitters")
		local boxes = TransmitterModel.transmitterBoxes(block, modes, 0, 0, 0, all)
		local bands = ofKind(boxes, "band")
		t.eq(#bands, 3, "bands on the PUSH and PULL sides")
		local up = find(boxes, "band", { 6.6, 1.5, 6.6 }, { 0, 5.25, 0 }, "push band up")
		t.ok(same(up.colour, TransmitterModel.PUSH_COLOUR), "push colour")
		local north = find(boxes, "band", { 6.6, 6.6, 1.5 }, { 0, 0, -5.25 }, "pull band north")
		t.ok(same(north.colour, TransmitterModel.PULL_COLOUR), "pull colour")
		find(boxes, "band", { 1.5, 6.6, 6.6 }, { -5.25, 0, 0 }, "pull band west")
		t.ok(not same(TransmitterModel.PULL_COLOUR, TransmitterModel.PUSH_COLOUR), "pull and push differ")
		-- Mixed: only the acceptor's side (west, PULL) has one.
		local mixed = TransmitterModel.transmitterBoxes(block, modes, 0, 0, bit(UP) + bit(NORTH), bit(WEST))
		t.eq(#ofKind(mixed, "band"), 1, "one band")
		find(mixed, "band", { 1.5, 6.6, 6.6 }, { -5.25, 0, 0 }, "the acceptor's band")
		-- No arm, no band: a configured side with nothing to connect to shows nothing.
		t.eq(#TransmitterModel.transmitterBoxes(block, modes, 0, 0, 0, 0), 0, "unconnected")
	end)

	t.test("transmitter client: coloured transporters are tinted, pipes never", function()
		local red = 15
		local rgb = Transmitters.colourRgb(red) :: { number }
		local boxes =
			TransmitterModel.transmitterBoxes(B.UltimateLogisticalTransporter, 0, red, 0, bit(EAST), bit(WEST))
		local tint = find(boxes, "tint", { 7.2, 7.2, 7.2 }, { 0, 0, 0 }, "tint")
		t.ok(same(tint.colour, rgb), "tint colour")
		for _, glass in ofKind(boxes, "glass") do
			t.ok(same(glass.colour, rgb), "arm glass in the dye's colour")
		end
		for _, frame in ofKind(boxes, "frame") do
			t.ok(same(frame.colour, Blocks.get(B.UltimateLogisticalTransporter).color), "frames keep the tier colour")
		end
		-- (Pipes have no colour: a stray one is ignored.)
		local pipe = TransmitterModel.transmitterBoxes(B.BasicMechanicalPipe, 0, red, 0, bit(EAST), 0)
		t.eq(#ofKind(pipe, "tint"), 0, "no tint on a pipe")
		t.ok(not same(ofKind(pipe, "glass")[1].colour, rgb), "pipe glass untouched")
		-- No colour: no tint.
		t.eq(
			#ofKind(TransmitterModel.transmitterBoxes(B.BasicLogisticalTransporter, 0, 0, 0, 1, 0), "tint"),
			0,
			"uncoloured"
		)
	end)

	t.test("transmitter client: water in a pipe follows its fill", function()
		local pipe = B.AdvancedMechanicalPipe
		local all = 63
		t.eq(#ofKind(TransmitterModel.transmitterBoxes(pipe, 0, 0, 0, all, 0), "water"), 0, "empty: no water")
		-- Transporters never show water, whatever the byte.
		t.eq(
			#ofKind(TransmitterModel.transmitterBoxes(B.BasicLogisticalTransporter, 0, 0, 255, all, 0), "water"),
			0,
			"no water in transporters"
		)
		local half =
			ofKind(TransmitterModel.transmitterBoxes(pipe, 0, 0, 128, bit(EAST) + bit(UP) + bit(DOWN), 0), "water")
		-- The core, the column down and the east arm (sides in order); not up (only a full pipe).
		t.eq(#half, 3, "half full: core, down, east")
		local core = half[1]
		t.ok(core.offset[1] == 0 and core.offset[3] == 0, "core first")
		t.near(core.size[2], 6.2 * 128 / 255, 1e-9, "core water height")
		t.near(core.offset[2] - core.size[2] / 2, -3.1, 1e-9, "core water stands on the bottom")
		local down = half[2]
		t.near(down.size[2], 4.75, 1e-9, "the column down is whole")
		t.near(down.offset[2] - down.size[2] / 2, -7.75, 1e-9, "down to the collar")
		local east = half[3]
		t.ok(east.offset[1] > 0, "east")
		t.near(east.size[2], 5.2 * 128 / 255, 1e-9, "arm water height")
		t.near(east.offset[2] - east.size[2] / 2, -2.6, 1e-9, "arm water on the bottom")
		t.near(east.offset[1] + east.size[1] / 2, 7.75, 1e-9, "arm water ends inside the collar")
		local plate = ofKind(TransmitterModel.transmitterBoxes(pipe, 0, 0, 128, 0, bit(EAST)), "water")[2]
		t.near(plate.offset[1] + plate.size[1] / 2, 7.25, 1e-9, "into a tank: ends inside the plate")
		local full = ofKind(TransmitterModel.transmitterBoxes(pipe, 0, 0, 255, bit(UP), 0), "water")
		t.eq(#full, 2, "full: core and up")
		t.ok(full[2].offset[2] > 0, "up holds water when full")
		-- A tiny fill still shows.
		local trace = ofKind(TransmitterModel.transmitterBoxes(pipe, 0, 0, 1, 0, 0), "water")
		t.eq(#trace, 1, "a trace of water")
		t.ok(trace[1].size[2] >= 0.2, "at least a sliver")
	end)

	t.test("transmitter client: a tank's water rises from its bottom plate", function()
		local tank = B.EliteFluidTank
		local capacity = Transmitters.tankCapacity(tank)
		t.eq(#TransmitterModel.tankBoxes(tank, 1, 0), 0, "empty")
		t.eq(#TransmitterModel.tankBoxes(B.Stone, 1, 1000), 0, "no tank")
		t.eq(#TransmitterModel.tankBoxes(tank, 1, 0 / 0), 0, "NaN")
		local half = TransmitterModel.tankBoxes(tank, 1, capacity / 2)
		t.eq(#half, 1, "one box")
		local e = extents(half[1])
		t.near(e[2][1], -5.9, 1e-9, "bottom just above the bottom plate (-6)")
		t.near(e[2][2], 0, 1e-9, "half way up")
		t.ok(e[1][1] > -7 and e[1][2] < 7 and e[3][1] > -7 and e[3][2] < 7, "inside the glass")
		local full = extents(TransmitterModel.tankBoxes(tank, 1, capacity * 2)[1])
		t.near(full[2][2], 5.9, 1e-9, "full: just under the top plate (6)")
		t.ok(same(half[1].colour, TransmitterModel.WATER_COLOUR), "water colour")
		local drop = extents(TransmitterModel.tankBoxes(tank, 1, 1)[1])
		t.ok(drop[2][2] - drop[2][1] >= 0.2 - 1e-9, "1 mB still shows")
	end)

	--[[ Aiming ]]

	t.test("transmitter client: side from a hit point", function()
		t.eq(TransmitterModel.sideFromPoint(0.5, 0.1, -0.2), EAST, "east face")
		t.eq(TransmitterModel.sideFromPoint(-0.5, 0.49, 0), WEST, "west face")
		t.eq(TransmitterModel.sideFromPoint(0.1, -0.5, 0.3), DOWN, "bottom")
		t.eq(TransmitterModel.sideFromPoint(0, 0, -0.3), NORTH, "north")
		t.eq(TransmitterModel.sideFromPoint(0.2, 0, 0.3), SOUTH, "south")
		t.eq(TransmitterModel.sideFromPoint(0.5, 0.5, 0.5), UP, "a corner: Y first")
		t.eq(TransmitterModel.sideFromPoint(0.5, 0, 0.5), SOUTH, "an edge: Z before X")
		t.eq(TransmitterModel.sideFromPoint(0, 0, 0), nil, "the centre")
	end)

	t.test("transmitter client: the Configurator picks the arm or core face it points at", function()
		local x, y, z = 10, 64, -5
		-- From the east at the centre: the core's east face, or the east arm when there is one.
		t.eq(TransmitterModel.pickSide(x + 3, y + 0.5, z + 0.5, -1, 0, 0, x, y, z, 0), EAST, "core east")
		t.eq(TransmitterModel.pickSide(x + 3, y + 0.5, z + 0.5, -1, 0, 0, x, y, z, bit(EAST)), EAST, "arm east")
		-- From above beside the core, over the west arm: that arm; without it the ray misses.
		t.eq(TransmitterModel.pickSide(x + 0.1, y + 3, z + 0.5, 0, -1, 0, x, y, z, bit(WEST)), WEST, "west arm")
		t.eq(TransmitterModel.pickSide(x + 0.1, y + 3, z + 0.5, 0, -1, 0, x, y, z, 0), nil, "nothing there")
		-- From above at the core, with arms all round: the core's top.
		t.eq(TransmitterModel.pickSide(x + 0.5, y + 3, z + 0.5, 0, -1, 0, x, y, z, 63 - bit(UP)), UP, "core top")
		-- An arm in front of the core wins: looking along the east arm from far east, slightly up.
		t.eq(TransmitterModel.pickSide(x + 5, y + 0.6, z + 0.45, -1, 0, 0, x, y, z, bit(EAST)), EAST, "arm first")
		-- Looking down at the north arm, straight or from the west: the arm; without it, nothing.
		t.eq(TransmitterModel.pickSide(x + 0.5, y + 3, z + 0.1, 0, -1, 0, x, y, z, bit(NORTH)), NORTH, "north arm")
		t.eq(TransmitterModel.pickSide(x - 0.5, y + 2.5, z + 0.1, 1, -1.8, 0, x, y, z, bit(NORTH)), NORTH, "slanted")
		t.eq(TransmitterModel.pickSide(x + 0.5, y + 3, z + 0.1, 0, -1, 0, x, y, z, bit(SOUTH)), nil, "no north arm")
		-- An acceptor's plate is wider than an arm: its corner still picks that side.
		local corner = { x + 0.5 + 0.28, y + 3, z + 0.03 }
		t.eq(TransmitterModel.pickSide(corner[1], corner[2], corner[3], 0, -1, 0, x, y, z, bit(NORTH)), nil, "arm")
		t.eq(
			TransmitterModel.pickSide(corner[1], corner[2], corner[3], 0, -1, 0, x, y, z, 0, bit(NORTH)),
			NORTH,
			"plate"
		)
		-- From inside the core: the face it looks out of.
		t.eq(TransmitterModel.pickSide(x + 0.5, y + 0.5, z + 0.5, 0.1, 0.2, 1, x, y, z, 0), SOUTH, "inside")
		-- Rays that miss the cell altogether.
		t.eq(TransmitterModel.pickSide(x + 3, y + 3, z + 0.5, -1, 0, 0, x, y, z, 63), nil, "above")
		t.eq(TransmitterModel.pickSide(x + 3, y + 0.5, z + 0.5, 1, 0, 0, x, y, z, 63), nil, "facing away")
		t.eq(TransmitterModel.pickSide(x + 3, y + 0.5, z + 0.5, 0, 0, 0, x, y, z, 63), nil, "no direction")
		-- A ray aimed at the centre from anywhere outside picks the face it comes from.
		local random = Hash.rng(7)
		for _ = 1, 500 do
			local vx, vy, vz = random:float() * 2 - 1, random:float() * 2 - 1, random:float() * 2 - 1
			local length = math.sqrt(vx * vx + vy * vy + vz * vz)
			if length > 0.1 then
				local ox, oy, oz = x + 0.5 + vx / length * 3, y + 0.5 + vy / length * 3, z + 0.5 + vz / length * 3
				local side = TransmitterModel.pickSide(ox, oy, oz, -vx, -vy, -vz, x, y, z, 0)
				t.eq(side, TransmitterModel.sideFromPoint(vx, vy, vz), `aimed from {vx}, {vy}, {vz}`)
			end
		end
	end)

	--[[ Items in transit ]]

	t.test("transmitter client: items move from face to face at the transporter's speed", function()
		local x, y, z = 0, 70, 0
		-- Basic: 5 progress a tick, 20 ticks a block; three blocks east.
		local route = TransmitterModel.route(x, y, z, 0, 5, { EAST, EAST, EAST })
		local function at(ticks: number)
			local px, py, pz, k, arrived = TransmitterModel.position(route, ticks)
			return px, py, pz, k, arrived
		end
		local px, py, pz, k, arrived = at(0)
		t.near(px, 0, 1e-9, "starts on the west face")
		t.near(py, 70.5, 1e-9, "at mid height")
		t.near(pz, 0.5, 1e-9, "in the middle")
		t.eq(k, 1, "first block")
		t.eq(arrived, false, "on the way")
		px = at(10)
		t.near(px, 0.5, 1e-9, "the centre at progress 50")
		px, _, _, k = at(25)
		t.near(px, 1.25, 1e-9, "a quarter into the second block")
		t.eq(k, 2, "second block")
		px, _, _, k, arrived = at(59.9)
		t.eq(arrived, false, "not yet")
		px, _, _, k, arrived = at(60)
		t.near(px, 3, 1e-9, "on the last face")
		t.eq(k, 3, "still the last block")
		t.eq(arrived, true, "arrived")
		px, _, _, _, arrived = at(1000)
		t.near(px, 3, 1e-9, "stays on the last face")
		t.ok(arrived, "arrived")
		-- Clock skew: before the start it waits where it was.
		px = at(-5)
		t.near(px, 0, 1e-9, "never before its start")
		t.near((at(0 / 0)), 0, 1e-9, "NaN ticks")
	end)

	t.test("transmitter client: each block is crossed at its own speed", function()
		-- Basic (5), then Ultimate (50), then unknown (the sent speed).
		local speeds = { [1] = 50 }
		local route = TransmitterModel.route(0, 70, 0, 50, 5, { EAST, EAST, EAST }, function(x: number)
			return speeds[x]
		end)
		t.eq(route.exits[1], 10, "half a basic block: 10 ticks")
		t.eq(route.exits[2], 12, "an ultimate block: 2 ticks")
		t.eq(route.exits[3], 32, "unknown: the sent speed, 20 ticks")
		t.eq(route.speeds[2], 50, "the ultimate's speed")
		t.eq(route.speeds[3], 5, "the sent speed")
		local px = TransmitterModel.position(route, 11)
		t.near(px, 1.5, 1e-9, "half way through the ultimate block after 1 tick")
		-- Stopped (speed 0): it stays where it is.
		local stopped = TransmitterModel.route(0, 70, 0, 30, 0, { EAST })
		t.eq(stopped.exits[1], math.huge, "never leaves")
		local sx = TransmitterModel.position(stopped, 500)
		t.near(sx, 0.3, 1e-9, "stays at progress 30")
		-- Waiting with no path: at the centre.
		local waiting = TransmitterModel.route(4, 70, 4, 80, 5, {})
		local wx, wy, wz, k, arrived = TransmitterModel.position(waiting, 100)
		t.ok(wx == 4.5 and wy == 70.5 and wz == 4.5, "waits at the centre")
		t.eq(k, 1, "in its block")
		t.eq(arrived, false, "has not arrived")
		-- Progress beyond 100 is clamped (the protocol allows a byte).
		local clamped = TransmitterModel.route(0, 70, 0, 255, 5, { EAST })
		t.eq(clamped.exits[1], 0, "at the face at once")
	end)

	t.test("transmitter client: items turn at the centre", function()
		-- East, then up: before the centre of the second block it moves east, after it up.
		local route = TransmitterModel.route(0, 70, 0, 0, 10, { EAST, UP, UP })
		local px, py = TransmitterModel.position(route, 12.5)
		t.near(px, 1.25, 1e-9, "x: a quarter into the second block, still moving east")
		t.near(py, 70.5, 1e-9, "y: at mid height")
		px, py = TransmitterModel.position(route, 17.5)
		t.near(px, 1.5, 1e-9, "x: on the centre line")
		t.near(py, 70.75, 1e-9, "y: going up")
		local qx, qy, _, k = TransmitterModel.position(route, 22.5)
		t.eq(k, 3, "third block")
		t.near(qx, 1.5, 1e-9, "above the second block")
		t.near(qy, 71.25, 1e-9, "coming in from below")
		local cx, cy, cz = TransmitterModel.cell(route, 3)
		t.ok(cx == 1 and cy == 71 and cz == 0, "third cell")
	end)

	t.test("transmitter client: items keep the way they came in up to the centre", function()
		-- Pulled up out of a chest below, then east: up to the centre it rises from the bottom face.
		local route = TransmitterModel.route(0, 70, 0, 0, 10, { EAST, EAST }, nil, UP)
		local px, py, pz = TransmitterModel.position(route, 0)
		t.ok(px == 0.5 and py == 70 and pz == 0.5, `on the bottom face, not the west one: {px}, {py}, {pz}`)
		px, py = TransmitterModel.position(route, 2.5)
		t.near(px, 0.5, 1e-9, "x: on the centre line")
		t.near(py, 70.25, 1e-9, "y: rising")
		px, py = TransmitterModel.position(route, 7.5)
		t.near(px, 0.75, 1e-9, "after the centre: east")
		t.near(py, 70.5, 1e-9, "at mid height")
		-- No entry, or a bad one: straight on.
		t.near((TransmitterModel.position(TransmitterModel.route(0, 70, 0, 0, 10, { EAST }), 0)), 0, 1e-9, "straight")
		t.eq(TransmitterModel.route(0, 70, 0, 0, 10, { EAST }, nil, 9).entry, nil, "a bad side is ignored")

		-- The way into a block of a route: the side the block before it was left by.
		local way = TransmitterModel.route(0, 70, 0, 20, 10, { EAST, NORTH, UP }, nil, SOUTH)
		t.eq(TransmitterModel.entryOf(way, 0, 70, 0), SOUTH, "the first block: the route's entry")
		t.eq(TransmitterModel.entryOf(way, 1, 70, 0), EAST, "the second")
		t.eq(TransmitterModel.entryOf(way, 1, 70, -1), NORTH, "the third")
		t.eq(TransmitterModel.entryOf(way, 5, 70, 0), nil, "not on the route")
		t.eq(TransmitterModel.entryOf(TransmitterModel.route(0, 70, 0, 20, 10, { EAST }), 0, 70, 0), nil, "unknown")

		-- Pulled items: out of the one PULL side on an inventory, towards the centre.
		local pullDown = Transmitters.packModes({ M.PULL, M.NORMAL, M.NORMAL, M.NORMAL, M.NORMAL, M.NORMAL })
		t.eq(TransmitterModel.pullEntry(pullDown, bit(DOWN) + bit(EAST)), UP, "from below: up")
		t.eq(TransmitterModel.pullEntry(pullDown, bit(EAST)), nil, "the PULL side has no inventory")
		local two = Transmitters.packModes({ M.PULL, M.NORMAL, M.NORMAL, M.NORMAL, M.PULL, M.NORMAL })
		t.eq(TransmitterModel.pullEntry(two, bit(DOWN) + bit(WEST)), nil, "two PULL sides: unknown")
		t.eq(TransmitterModel.pullEntry(two, bit(WEST)), EAST, "the one on an inventory: from the west, east")
		t.eq(TransmitterModel.pullEntry(0, 63), nil, "no PULL side")
		-- Items a furnace or machine pushed out: from its NORMAL side when there is no PULL side.
		t.eq(TransmitterModel.pullEntry(0, bit(WEST) + bit(EAST), bit(WEST)), EAST, "out of the furnace on the west")
		t.eq(TransmitterModel.pullEntry(0, bit(WEST), 0), nil, "no furnace there")
		t.eq(TransmitterModel.pullEntry(0, bit(WEST) + bit(EAST), bit(WEST) + bit(EAST)), nil, "two furnaces: unknown")
		local pushWest = Transmitters.packModes({ M.NORMAL, M.NORMAL, M.NORMAL, M.NORMAL, M.PUSH, M.NORMAL })
		t.eq(
			TransmitterModel.pullEntry(pushWest, bit(WEST) + bit(UP), bit(WEST) + bit(UP)),
			DOWN,
			"PUSH sides take nothing"
		)
		t.eq(TransmitterModel.pullEntry(pullDown, bit(DOWN) + bit(WEST), bit(WEST)), UP, "a PULL side first")
	end)

	t.test("transmitter client: a route sent again goes on where the item was (fuzz)", function()
		-- The server sends a new route (re-routed, a new speed) from the block an item is in and its
		-- progress there; with the way in taken from the old route the item does not jump.
		local random = Hash.rng(23)
		local speedsByTier = { 5, 10, 20, 50 }
		local checked = 0
		for _ = 1, 300 do
			-- (A route never visits a block twice: the server's are shortest ways.)
			local path = {}
			local visited = { ["0,300,0"] = true }
			local x, y, z = 0, 300, 0
			for _ = 1, random:int(2, 10) do
				local side = random:int(0, 5)
				local dx, dy, dz = Transmitters.offset(side)
				local key = `{x + dx},{y + dy},{z + dz}`
				if not visited[key] then
					visited[key] = true
					x, y, z = x + dx, y + dy, z + dz
					table.insert(path, side)
				end
			end
			local n = #path
			local tiers = {}
			local function speedAt(x: number, y: number, z: number): number
				local key = `{x},{y},{z}`
				if tiers[key] == nil then
					tiers[key] = speedsByTier[random:int(1, 4)]
				end
				return tiers[key]
			end
			local old = TransmitterModel.route(
				0,
				300,
				0,
				random:int(0, 49),
				speedAt(0, 300, 0),
				path,
				speedAt,
				random:int(0, 5)
			)
			local ticks = random:float() * (old.exits[n] or 0)
			local px, py, pz, k, arrived = TransmitterModel.position(old, ticks)
			if n > 0 and not arrived then
				-- Its progress in block k at that moment, and the rest of its way from there.
				local progress = if k == 1
					then old.progress + ticks * old.speeds[1]
					else 100 - (old.exits[k] - ticks) * old.speeds[k]
				local x, y, z = TransmitterModel.cell(old, k)
				local rest = table.move(path, k, n, 1, {})
				local new = TransmitterModel.route(
					x,
					y,
					z,
					progress,
					old.speeds[k],
					rest,
					speedAt,
					TransmitterModel.entryOf(old, x, y, z)
				)
				local qx, qy, qz = TransmitterModel.position(new, 0)
				local jump = math.abs(qx - px) + math.abs(qy - py) + math.abs(qz - pz)
				t.ok(jump < 1e-6, `a jump of {jump} (block {k}, progress {progress})`)
				checked += 1
			end
		end
		t.ok(checked > 200, "routes checked")
	end)

	t.test("transmitter client: item paths are continuous and stay in their block (fuzz)", function()
		local random = Hash.rng(11)
		local speedsByTier = { 5, 10, 20, 50 }
		for _ = 1, 200 do
			local n = random:int(0, 12)
			local path = {}
			local last = random:int(0, 5)
			for i = 1, n do
				-- (Never straight back: a transporter path does not reverse.)
				local side = random:int(0, 5)
				while side == Transmitters.opposite(last) do
					side = random:int(0, 5)
				end
				path[i] = side
				last = side
			end
			local perBlock = {}
			local route = TransmitterModel.route(
				0,
				500,
				0,
				random:int(0, 100),
				speedsByTier[random:int(1, 4)],
				path,
				function(x: number, y: number, z: number)
					local key = `{x},{y},{z}`
					if perBlock[key] == nil then
						perBlock[key] = speedsByTier[random:int(1, 4)]
					end
					return perBlock[key]
				end
			)
			local dt = 0.25
			local px, py, pz = TransmitterModel.position(route, 0)
			for step = 1, 2400 do
				local qx, qy, qz, k, arrived = TransmitterModel.position(route, step * dt)
				local jump = math.abs(qx - px) + math.abs(qy - py) + math.abs(qz - pz)
				t.ok(jump <= 50 * dt / 100 + 1e-9, `a jump of {jump} at step {step}`)
				local cx, cy, cz = TransmitterModel.cell(route, k)
				t.ok(
					qx >= cx - 1e-9
						and qx <= cx + 1 + 1e-9
						and qy >= cy - 1e-9
						and qy <= cy + 1 + 1e-9
						and qz >= cz - 1e-9
						and qz <= cz + 1 + 1e-9,
					"inside its block"
				)
				px, py, pz = qx, qy, qz
				if arrived then
					break
				end
			end
		end
	end)

	--[[ WAILA ]]

	local function facts(overrides: { [string]: any })
		local base = {
			modes = 0,
			colour = 0,
			fluid = 0,
			side = nil,
			items = 0,
			stacks = 0,
			transmitters = 0,
			acceptors = 0,
			networkSize = 1,
			networkCapacity = 0,
			networkComplete = true,
		}
		for key, value in overrides do
			base[key] = value
		end
		return base
	end

	local function texts(info): { string }
		return WailaInfo.texts(info)
	end

	local function has(list: { string }, text: string, what: string)
		for _, line in list do
			if line == text then
				return
			end
		end
		error(`{what}: no "{text}" in: {table.concat(list, " | ")}`, 2)
	end

	local function hasNo(list: { string }, prefix: string, what: string)
		for _, line in list do
			if string.sub(line, 1, #prefix) == prefix then
				error(`{what}: unexpected "{line}"`, 2)
			end
		end
	end

	t.test("transmitter client: thousands separators", function()
		t.eq(WailaInfo.thousands(0), "0", "0")
		t.eq(WailaInfo.thousands(999), "999", "999")
		t.eq(WailaInfo.thousands(1000), "1,000", "1000")
		t.eq(WailaInfo.thousands(32000), "32,000", "32000")
		t.eq(WailaInfo.thousands(256000), "256,000", "256000")
		t.eq(WailaInfo.thousands(1234567), "1,234,567", "1234567")
		t.eq(WailaInfo.thousands(-4500), "-4,500", "negative")
		t.eq(WailaInfo.thousands(2.6), "3", "rounded")
	end)

	t.test("transmitter client: WAILA names a transporter's side, colour and items", function()
		local block = B.EliteLogisticalTransporter
		local modes = Transmitters.withMode(0, EAST, M.PULL)
		local info = WailaInfo.block(block, nil, 1, 64, 1, false, {
			transmitter = facts({ modes = modes, colour = 15, side = EAST, items = 12, stacks = 2 }),
		})
		local lines = texts(info)
		t.eq(lines[1], "Elite Logistical Transporter", "name")
		has(lines, "✔ Tool: Pickaxe", "harvest")
		has(lines, "Side: Pull", "the side pointed at")
		has(lines, "Colour: Red", "colour")
		has(lines, "Items: 12", "items inside")
		t.eq(lines[#lines], "IceVoxel", "mod name last")
		-- Another side, no colour, nothing inside.
		local plain = texts(WailaInfo.block(block, nil, 1, 64, 1, false, {
			transmitter = facts({ modes = modes, side = WEST }),
		}))
		has(plain, "Side: Normal", "west is normal")
		has(plain, "Colour: None", "no colour")
		hasNo(plain, "Items", "nothing inside")
		-- No side picked (aiming beside it): no side line.
		hasNo(texts(WailaInfo.block(block, nil, 1, 64, 1, false, { transmitter = facts({}) })), "Side", "no side")
		-- Without facts (or for other blocks) nothing is added.
		local bare = texts(WailaInfo.block(block, nil, 1, 64, 1, false))
		t.eq(#bare, 3, "name, harvest, mod")
		local stone = texts(WailaInfo.block(B.Stone, nil, 1, 64, 1, false, { transmitter = facts({ side = UP }) }))
		hasNo(stone, "Side", "not on stone")
		t.eq(WailaInfo.blockName(B.RestrictiveTransporter), "Restrictive Transporter", "restrictive name")
	end)

	t.test("transmitter client: WAILA shows a pipe's water and a tank's", function()
		local pipe = B.BasicMechanicalPipe
		local empty = texts(WailaInfo.block(pipe, nil, 0, 64, 0, false, { transmitter = facts({ side = UP }) }))
		has(empty, "Empty: 0 / 2,000 mB", "a lone empty pipe: its own capacity")
		hasNo(empty, "Colour", "pipes have no colour")
		local full = texts(WailaInfo.block(pipe, nil, 0, 64, 0, false, {
			transmitter = facts({ fluid = 255, networkSize = 8, networkCapacity = 16000 }),
		}))
		has(full, "Water: 16,000 / 16,000 mB", "a full network")
		local part = texts(WailaInfo.block(pipe, nil, 0, 64, 0, false, {
			transmitter = facts({ fluid = 128, networkSize = 8, networkCapacity = 16000 }),
		}))
		has(part, `Water: ~{WailaInfo.thousands(Transmitters.fillAmount(128, 16000))} / 16,000 mB`, "approximate")
		local tank = B.BasicFluidTank
		local lines = texts(WailaInfo.block(tank, nil, 0, 64, 0, false, { tank = { fluid = 1, amount = 12000 } }))
		t.eq(lines[1], "Basic Fluid Tank", "tank name")
		has(lines, "Water: 12,000 / 32,000 mB", "tank contents")
		has(
			texts(WailaInfo.block(B.UltimateFluidTank, nil, 0, 64, 0, false, { tank = { fluid = 0, amount = 0 } })),
			"Empty: 0 / 256,000 mB",
			"an empty tank"
		)
		-- Tank facts on a transmitter (or the other way round) are ignored.
		hasNo(
			texts(WailaInfo.block(pipe, nil, 0, 64, 0, false, { tank = { fluid = 1, amount = 5 } })),
			"Water",
			"wrong facts"
		)
	end)

	t.test("transmitter client: WAILA's F3 lines show modes, connections and the network", function()
		local block = B.AdvancedLogisticalTransporter
		local modes = Transmitters.packModes({ M.NORMAL, M.PULL, M.PUSH, M.NONE, M.NORMAL, M.NORMAL })
		local lines = texts(WailaInfo.block(block, nil, 3, 64, 3, true, {
			transmitter = facts({
				modes = modes,
				colour = 4,
				transmitters = bit(EAST) + bit(WEST),
				acceptors = bit(DOWN),
				networkSize = 5,
				items = 3,
				stacks = 1,
			}),
		}))
		has(lines, "Transporter tier 2 (Advanced), pull 16, speed 10, cost 5", "tier numbers")
		has(lines, string.format("Modes 0x%03X: D Normal, U Pull, N Push, S None, W Normal, E Normal", modes), "modes")
		has(lines, "Colour 4, fill 0 / 255", "colour and fill")
		has(lines, "Connected: transmitters W, E; acceptors D", "connections")
		has(lines, "Network 5 transmitters", "network")
		has(lines, "In transit 1 stacks, 3 items", "items")
		t.eq(lines[#lines], "IceVoxel", "mod name last")
		local restrictive =
			texts(WailaInfo.block(B.RestrictiveTransporter, nil, 0, 64, 0, true, { transmitter = facts({}) }))
		has(restrictive, "Transporter tier 1 (Basic, restrictive), pull 1, speed 5, cost 1000", "restrictive")
		local pipe = texts(WailaInfo.block(B.EliteMechanicalPipe, nil, 0, 64, 0, true, {
			transmitter = facts({ networkSize = 4096, networkCapacity = 131072000, networkComplete = false }),
		}))
		has(pipe, "Pipe tier 3 (Elite), 32,000 mB, pull 8,000 mB/t", "pipe numbers")
		has(pipe, "Network 4096+ transmitters, 131,072,000+ mB", "an unfinished walk")
		has(pipe, "Connected: transmitters none; acceptors none", "nothing connected")
		local tank =
			texts(WailaInfo.block(B.AdvancedFluidTank, nil, 0, 64, 0, true, { tank = { fluid = 1, amount = 500 } }))
		has(tank, "Tank tier 2 (Advanced), output 4,000 mB/t", "tank numbers")
		has(tank, "Fluid 1 (Water), 500 mB", "tank fluid")
	end)
end

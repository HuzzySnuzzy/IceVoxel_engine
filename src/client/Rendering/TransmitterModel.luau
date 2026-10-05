--!strict
--[[
	What the client draws for Mekanism's transmitters, fluid tanks and machines, and the maths of
	aiming at them and of items moving through them. Plain numbers only (no Roblox APIs), so the
	tests check it; Rendering/TransmitterRenderer turns the boxes into parts and moves the items.

	Boxes are axis-aligned, in pixels (1/16 block) from the cell's centre, like BlockList shapes.
	The block's own `shape` (Mekanism's 8 pixel core: a glass cube in a frame of twelve edges, drawn
	by the terrain; a Universal Cable's is Mekanism's small 6 pixel core, `sizes`) stays as it is;
	these boxes go around and inside it:

	  arms     towards every side that connects (Transmitters.connections): a glass tube ARM pixels
	           across from the core's frame to the cell's face. Between two transmitters it ends in
	           a collar in the tier's colour (the neighbour's collar meets it: a joint two pixels
	           long); into an acceptor (chest, furnace, tank, energy block) it ends in a wider
	           connector plate. A Universal Cable's arm is its red-ish conductor ("cable": opaque),
	           4 pixels across, with a 5 pixel collar and an 8 pixel plate.
	  bands    a glowing ring around an arm into an acceptor whose side is PUSH (orange) or PULL
	           (blue): Mekanism tints configured connections; these are the client's colours for
	           them. Between two transmitters PUSH and PULL act as NORMAL, and Mekanism draws them
	           so (Transmitter.getConnectionType), so those arms carry no band; nor do cables',
	           whose PUSH and PULL act as NORMAL everywhere (server Machines/EnergyNet).
	  colour   a coloured transporter (dye 1..16) gets a translucent cube of its colour around the
	           core's glass, and its arms' glass in that colour (Mekanism tints the transporter).
	  water    a Mechanical Pipe's fill (Protocol `Transmitters.fluid`, 0..255): a water box in the
	           core and in each sideways arm, its height the fill; the arm down is a full column
	           as soon as there is any water, the arm up only when the pipe is (nearly) full.
	  tanks    a Fluid Tank's water, from the bottom plate up to amount / capacity of the inside.
	  machines what a Mekanism machine shows from its Machines record (`machineBoxes`): a burning
	           Heat Generator's fuel window glows on its four sides.

	Aiming (`pickSide`): the Configurator acts on the side it points at, as in Mekanism: an arm's
	side when the ray hits that arm (aimed at as wide as its collar, or its plate into an
	acceptor), else the face of the core it hits. A ray that misses them all (it passes through
	the cell beside them) gives nil, and Interaction/BlockInteraction falls back to `sideFromPoint`
	of where it hit the cell: the axis on which that point is furthest from the cell's centre, by
	its sign (so a side with no arm is picked by aiming at the core or the cell from that side).

	Items in transit (`route`, `position`): the server sends where an item is (a transporter, its
	progress 0..100 through it, the progress per tick there and the server time of that), and the
	sides it leaves each block through. Progress 0 is the face it came in by, 50 the centre and 100
	the face it leaves by (Mekanism's TransporterStack: before 50 it moves along the way it came,
	from 50 on along the way it goes). The way it came into the first block is not sent: the
	renderer passes it when it knows it (`entryOf` the item's previous route, `pullEntry` for an
	item just pulled out of an inventory), else the item comes in straight. The item crosses each
	block at that block's speed (the transporter's tier, Transmitters.speed; the sent speed where
	the block is unknown) and has arrived when it leaves the last one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Machines = require(Shared.Machines)
local Transmitters = require(Shared.Transmitters)

local BlockDecor = require(script.Parent.BlockDecor)

export type BoxKind = "glass" | "frame" | "band" | "tint" | "water" | "cable" | "glow"

-- One box: its look (`kind`, `colour`), size and centre in pixels from the cell's centre.
export type Box = { kind: BoxKind, size: { number }, offset: { number }, colour: { number } }

export type Route = {
	-- The blocks the item goes through, x, y, z each (block k at 3k + 1 .. 3k + 3), starting with
	-- the one it is in; one block when it has no path (it waits there).
	cells: { number },
	-- The side each block is left through (Protocol `Transport` path).
	path: { number },
	-- Progress per tick in each block.
	speeds: { number },
	-- Ticks after the start at which the item leaves each block (math.huge: never, it waits).
	exits: { number },
	-- Progress through the first block at the start.
	progress: number,
	-- The way the item moves through the first block before its centre (a side; nil: straight
	-- on, path[1]).
	entry: number?,
}

local TransmitterModel = {}

--[[ Sizes (pixels) ]]

-- Half the core with its frame (Mekanism's 8 pixel core).
TransmitterModel.CORE = 4
-- Arms: the glass tube across, the collar between two transmitters and the plate on an acceptor.
TransmitterModel.ARM = 6
TransmitterModel.COLLAR = 7
TransmitterModel.PLATE = 10
-- A PUSH / PULL band: across, and from / to along the arm.
local BAND = 6.6
local BAND_FROM, BAND_TO = 4.5, 6
-- The colour cube around a coloured transporter's core glass (7 pixels).
local TINT = 7.2
-- Water: across in the core and in the arms (inside the 7 and 6 pixel glass); where arm water
-- starts (overlapping the core's, never sharing a face with it) and ends (inside the collar or
-- the plate, so its end is never seen).
local CORE_WATER = 6.2
local ARM_WATER = 5.2
local ARM_WATER_FROM = 3
local ARM_WATER_TO, ARM_WATER_TO_ACCEPTOR = 7.75, 7.25
-- Glass ends inside the collar / plate too (no face shared with them).
local ARM_GLASS_TO, ARM_GLASS_TO_ACCEPTOR = 7.5, 7.25
-- Fill (0..1) from which the arm up holds water.
TransmitterModel.UP_FULL = 0.95
-- A tank's water: across (inside its 14 pixel glass), its bottom just above the bottom plate and
-- its full height up to just under the top plate.
local TANK_WATER = 13
local TANK_BOTTOM = -5.9
local TANK_HEIGHT = 11.8
-- The lowest water box drawn (pixels), so a nearly empty tank or pipe still shows some.
local MIN_WATER = 0.2

--[[ Colours ]]

TransmitterModel.PULL_COLOUR = table.freeze({ 64, 160, 255 })
TransmitterModel.PUSH_COLOUR = table.freeze({ 255, 140, 40 })
-- Water as the world draws it (BlockList "Water").
TransmitterModel.WATER_COLOUR = table.freeze({ 44, 106, 196 })

local CORE = TransmitterModel.CORE
local ARM = TransmitterModel.ARM
local COLLAR = TransmitterModel.COLLAR
local PLATE = TransmitterModel.PLATE
local DOWN, UP = Transmitters.DOWN, Transmitters.UP
local PULL, PUSH = Transmitters.MODES.PULL, Transmitters.MODES.PUSH

-- A transmitter's sizes (pixels): half its core with the frame, and its arms' tube, collar and
-- plate across.
export type Sizes = { core: number, arm: number, collar: number, plate: number }

local LARGE: Sizes = table.freeze({ core = CORE, arm = ARM, collar = COLLAR, plate = PLATE })
-- Mekanism's small transmitters (Universal Cables): a 6 pixel core.
local SMALL: Sizes = table.freeze({ core = 3, arm = 4, collar = 5, plate = 8 })
TransmitterModel.SMALL = SMALL
TransmitterModel.LARGE = LARGE

-- The sizes of the transmitter `block` (small for Universal Cables, else Mekanism's large ones).
function TransmitterModel.sizes(block: number?): Sizes
	return if block and Transmitters.kindOf(block) == "energy" then SMALL else LARGE
end

--[[ Boxes ]]

local function box(kind: BoxKind, size: { number }, offset: { number }, colour: { number }): Box
	return { kind = kind, size = size, offset = offset, colour = colour }
end

--[[
	A box along `side` from `from` to `to` pixels out of the centre. Across it is `width` wide and,
	for a sideways side, `height` tall with its centre `lift` above the cell's centre (a side up or
	down is `width` square).
]]
local function along(
	kind: BoxKind,
	side: number,
	from: number,
	to: number,
	width: number,
	height: number,
	lift: number,
	colour: { number }
): Box
	local dx, dy, dz = Transmitters.offset(side)
	local length, mid = to - from, (from + to) / 2
	if dy ~= 0 then
		return box(kind, { width, length, width }, { 0, dy * mid, 0 }, colour)
	elseif dx ~= 0 then
		return box(kind, { length, height, width }, { dx * mid, lift, 0 }, colour)
	end
	return box(kind, { width, height, length }, { 0, lift, dz * mid }, colour)
end

-- The tier's colour (the frame) and the glass colour of a transmitter (its core's first box).
local function looks(block: number): ({ number }, { number })
	local def = Blocks.get(block)
	local first = if def.shape then def.shape[1] else nil
	local glass: { number } = def.color
	if first and first.color then
		glass = first.color
	end
	return def.color, glass
end

-- A pipe's fill byte as 0..1 (0 for anything but a Mechanical Pipe).
local function fillOf(block: number, fluid: number): number
	if Transmitters.kindOf(block) ~= "fluid" or fluid ~= fluid then
		return 0
	end
	return math.clamp(fluid / 255, 0, 1)
end

--[[
	The boxes drawn over the transmitter `block` (on top of its core) with packed `modes`, dye
	`colour` (transporters only) and fill byte `fluid` (pipes only), connected to transmitters on
	the sides in `transmitterMask` and to acceptors on those in `acceptorMask` (bit `side`, as
	Transmitters.connections gives them). Empty for blocks that are no transmitter.
]]
function TransmitterModel.transmitterBoxes(
	block: number,
	modes: number,
	colour: number,
	fluid: number,
	transmitterMask: number,
	acceptorMask: number
): { Box }
	local boxes: { Box } = {}
	local kind = Transmitters.kindOf(block)
	if kind == nil then
		return boxes
	end
	local frame, glass = looks(block)
	local dye = if kind == "item" then Transmitters.colourRgb(colour) else nil
	local armGlass = dye or glass
	local sizes = TransmitterModel.sizes(block)
	local armKind: BoxKind = if kind == "energy" then "cable" else "glass"
	if dye then
		table.insert(boxes, box("tint", { TINT, TINT, TINT }, { 0, 0, 0 }, dye))
	end
	local fill = fillOf(block, fluid)
	local water = TransmitterModel.WATER_COLOUR
	if fill > 0 then
		local height = math.max(CORE_WATER * fill, MIN_WATER)
		table.insert(
			boxes,
			box("water", { CORE_WATER, height, CORE_WATER }, { 0, -CORE_WATER / 2 + height / 2, 0 }, water)
		)
	end
	for side = 0, 5 do
		local bit = bit32.lshift(1, side)
		local toAcceptor = bit32.band(acceptorMask, bit) ~= 0
		if toAcceptor or bit32.band(transmitterMask, bit) ~= 0 then
			local glassTo = if toAcceptor then ARM_GLASS_TO_ACCEPTOR else ARM_GLASS_TO
			table.insert(boxes, along(armKind, side, sizes.core, glassTo, sizes.arm, sizes.arm, 0, armGlass))
			if toAcceptor then
				table.insert(boxes, along("frame", side, 7, 8, sizes.plate, sizes.plate, 0, frame))
			else
				table.insert(boxes, along("frame", side, 7, 8, sizes.collar, sizes.collar, 0, frame))
			end
			local mode = Transmitters.modeOf(modes, side)
			if toAcceptor and kind ~= "energy" and (mode == PULL or mode == PUSH) then
				local band = if mode == PULL then TransmitterModel.PULL_COLOUR else TransmitterModel.PUSH_COLOUR
				table.insert(boxes, along("band", side, BAND_FROM, BAND_TO, BAND, BAND, 0, band))
			end
			if fill > 0 then
				local waterTo = if toAcceptor then ARM_WATER_TO_ACCEPTOR else ARM_WATER_TO
				if side == DOWN or (side == UP and fill >= TransmitterModel.UP_FULL) then
					-- (Water runs down a pipe whatever its level; it only stands up to the top when
					-- the pipe is full.)
					table.insert(boxes, along("water", side, ARM_WATER_FROM, waterTo, ARM_WATER, ARM_WATER, 0, water))
				elseif side ~= UP then
					local height = math.max(ARM_WATER * fill, MIN_WATER)
					local lift = -ARM_WATER / 2 + height / 2
					table.insert(boxes, along("water", side, ARM_WATER_FROM, waterTo, ARM_WATER, height, lift, water))
				end
			end
		end
	end
	return boxes
end

--[[
	The water inside the fluid tank `block` holding `amount` mB of `fluid`: one box from the bottom
	up to amount / capacity of the inside, or none when it is empty or no tank.
]]
function TransmitterModel.tankBoxes(block: number, _fluid: number, amount: number): { Box }
	local capacity = Transmitters.tankCapacity(block)
	if capacity <= 0 or amount ~= amount or amount <= 0 then
		return {}
	end
	-- (The fluid: water is the only one; anything else is drawn like it.)
	local fill = math.clamp(amount / capacity, 0, 1)
	local height = math.max(TANK_HEIGHT * fill, MIN_WATER)
	return {
		box(
			"water",
			{ TANK_WATER, height, TANK_WATER },
			{ 0, TANK_BOTTOM + height / 2, 0 },
			TransmitterModel.WATER_COLOUR
		),
	}
end

--[[ Machines ]]

-- What a machine's boxes are drawn from: its Machines record (Protocol.MachineRecord) or less.
export type MachineLook = { active: boolean, energy: number, capacity: number }

-- A lit window's colour (a furnace's fire) and how far it stands out of the face (pixels).
TransmitterModel.GLOW_COLOUR = table.freeze({ 255, 138, 44 })
TransmitterModel.GLOW_DEPTH = 0.2

-- Machines whose window lights while they work, by BlockList `decor`: the window on each side face
-- (BlockDecor pixels, from the face's top left), the same rectangle their decor draws dark.
local GLOWS: { [string]: { x: number, y: number, w: number, h: number } } = {
	HeatGenerator = BlockDecor.GENERATOR_WINDOW,
}
local SIDE_FACES = { "Front", "Back", "Left", "Right" }

local function glowOf(block: number): { x: number, y: number, w: number, h: number }?
	if not Machines.isMachine(block) or not Blocks.isValid(block) then
		return nil
	end
	local decor = Blocks.get(block).decor
	return if decor then GLOWS[decor] else nil
end

-- Does the machine `block` show anything over its faces (TransmitterRenderer keeps a cell for it)?
function TransmitterModel.hasMachineBoxes(block: number): boolean
	return glowOf(block) ~= nil
end

--[[
	The boxes drawn over the machine `block` from what its record says (`look`, nil: none came, an
	idle machine), and a signature of what they show (equal signatures, equal boxes). A Heat
	Generator that burns (active) lights its fuel window on its four sides: a thin glowing pane
	GLOW_DEPTH out of each face over the window its decor draws. Nothing for other blocks.
]]
function TransmitterModel.machineBoxes(block: number, look: MachineLook?): ({ Box }, string)
	local glow = glowOf(block)
	local active = look ~= nil and look.active
	if glow == nil or not active then
		return {}, `m{block}`
	end
	local boxes: { Box } = {}
	local depth = TransmitterModel.GLOW_DEPTH
	local across = glow.x + glow.w / 2 - 8
	local up = 8 - (glow.y + glow.h / 2)
	for _, face in SIDE_FACES do
		local normal, right = BlockDecor.basis(face)
		local size, offset = table.create(3, 0), table.create(3, 0)
		for k = 1, 3 do
			local n, r = math.abs(normal[k]), math.abs(right[k])
			size[k] = n * depth + r * glow.w + (if k == 2 then glow.h else 0)
			offset[k] = normal[k] * (8 + depth / 2) + right[k] * across + (if k == 2 then up else 0)
		end
		table.insert(boxes, box("glow", size, offset, TransmitterModel.GLOW_COLOUR))
	end
	return boxes, `m{block} lit`
end

--[[ Aiming ]]

--[[
	The side a point (relative to the cell's centre) is on: the axis on which it is furthest from
	the centre, by its sign. Ties go to Y, then Z, then X; nil for the centre itself.
]]
function TransmitterModel.sideFromPoint(px: number, py: number, pz: number): number?
	local ax, ay, az = math.abs(px), math.abs(py), math.abs(pz)
	if ay >= az and ay >= ax then
		if ay == 0 then
			return nil
		end
		return if py < 0 then Transmitters.DOWN else Transmitters.UP
	elseif az >= ax then
		return if pz < 0 then Transmitters.NORTH else Transmitters.SOUTH
	end
	return if px < 0 then Transmitters.WEST else Transmitters.EAST
end

--[[
	Where a ray (o + t d, d of any length; t along it as a unit vector) meets the box lo..hi: the
	entry distance and the axis it enters through (1..3), or 0 for the axis when it starts inside;
	nil when it misses or the box is behind.
]]
local function enter(o: { number }, d: { number }, lo: { number }, hi: { number }): (number?, number)
	local near, far, axis = -math.huge, math.huge, 0
	for k = 1, 3 do
		if math.abs(d[k]) < 1e-12 then
			if o[k] < lo[k] or o[k] > hi[k] then
				return nil, 0
			end
		else
			local t1, t2 = (lo[k] - o[k]) / d[k], (hi[k] - o[k]) / d[k]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			if t1 > near then
				near, axis = t1, k
			end
			far = math.min(far, t2)
		end
	end
	if near > far or far < 0 then
		return nil, 0
	end
	if near < 0 then
		return 0, 0
	end
	return near, axis
end

-- The side of axis k (1 X, 2 Y, 3 Z) on the `sign` side.
local function axisSide(k: number, sign: number): number
	if k == 1 then
		return if sign < 0 then Transmitters.WEST else Transmitters.EAST
	elseif k == 2 then
		return if sign < 0 then Transmitters.DOWN else Transmitters.UP
	end
	return if sign < 0 then Transmitters.NORTH else Transmitters.SOUTH
end

--[[
	The side of the transmitter at (x, y, z) a ray (origin and direction in blocks) points at, as
	Mekanism's Configurator picks it: the side of the arm it hits first (arms to transmitters on
	the sides in `arms`, to acceptors on those in `acceptorArms`: masks of bit `side`), else the
	face of the core it enters by. nil when it misses the core and every arm (it passes through
	the cell beside them). A ray starting inside the core picks the side it looks out of. Arms are
	aimed at as wide as their collars, or plates into acceptors; `block` gives the sizes
	(`sizes`: a Universal Cable's are smaller; nil: Mekanism's large transmitters).
]]
function TransmitterModel.pickSide(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	x: number,
	y: number,
	z: number,
	arms: number,
	acceptorArms: number?,
	block: number?
): number?
	local sizes = TransmitterModel.sizes(block)
	local armHalf = sizes.collar / 2 / 16
	local plateHalf = sizes.plate / 2 / 16
	local coreHalf = sizes.core / 16
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length < 1e-9 then
		return nil
	end
	local d = { dx / length, dy / length, dz / length }
	local o = { ox - x - 0.5, oy - y - 0.5, oz - z - 0.5 }
	local bestDistance, bestSide = math.huge, nil :: number?
	local t, axis = enter(o, d, { -coreHalf, -coreHalf, -coreHalf }, { coreHalf, coreHalf, coreHalf })
	if t then
		bestDistance = t
		if axis ~= 0 then
			bestSide = axisSide(axis, -d[axis])
		else
			-- Inside the core: the face it looks out of (the axis whose slab it leaves first).
			local exitAxis, exitDistance = 1, math.huge
			for k = 1, 3 do
				if math.abs(d[k]) > 1e-12 then
					local toFace = (coreHalf - o[k] * math.sign(d[k])) / math.abs(d[k])
					if toFace < exitDistance then
						exitAxis, exitDistance = k, toFace
					end
				end
			end
			bestSide = axisSide(exitAxis, d[exitAxis])
		end
	end
	local plates = acceptorArms or 0
	for side = 0, 5 do
		local bit = bit32.lshift(1, side)
		local plate = bit32.band(plates, bit) ~= 0
		if plate or bit32.band(arms, bit) ~= 0 then
			local sx, sy, sz = Transmitters.offset(side)
			local s = { sx, sy, sz }
			local half = if plate then plateHalf else armHalf
			local lo, hi = table.create(3, -half), table.create(3, half)
			for k = 1, 3 do
				if s[k] > 0 then
					lo[k], hi[k] = coreHalf, 0.5
				elseif s[k] < 0 then
					lo[k], hi[k] = -0.5, -coreHalf
				end
			end
			local armDistance = enter(o, d, lo, hi)
			if armDistance and armDistance < bestDistance then
				bestDistance, bestSide = armDistance, side
			end
		end
	end
	return bestSide
end

--[[ Items in transit ]]

--[[
	The way an item goes: it is in block (x, y, z) at `progress` (0..100) moving `speed` progress
	per tick, and leaves each block through the sides in `path` (the first leaving (x, y, z)).
	`speedAt(x, y, z)` gives the progress per tick of the blocks further on (Transmitters.speed of
	the transporter there; nil or 0 where it is unknown, which takes `speed`). `entry` is the way
	it moved when it came into (x, y, z) (a side), which it keeps up to the centre; nil: straight
	on, along path[1].
]]
function TransmitterModel.route(
	x: number,
	y: number,
	z: number,
	progress: number,
	speed: number,
	path: { number },
	speedAt: ((x: number, y: number, z: number) -> number?)?,
	entry: number?
): Route
	local start = if progress == progress then math.clamp(progress, 0, 100) else 0
	local first = if speed == speed then math.max(speed, 0) else 0
	local cells: { number } = { x, y, z }
	local speeds: { number } = { first }
	local exits: { number } = {}
	local cx, cy, cz = x, y, z
	local time = if first > 0 then (100 - start) / first else math.huge
	for k, side in path do
		exits[k] = time
		if k == #path then
			break
		end
		local ox, oy, oz = Transmitters.offset(side)
		cx, cy, cz = cx + ox, cy + oy, cz + oz
		table.insert(cells, cx)
		table.insert(cells, cy)
		table.insert(cells, cz)
		local s: number = (if speedAt then speedAt(cx, cy, cz) else nil) or 0
		if s <= 0 then
			s = first
		end
		speeds[k + 1] = s
		time += if s > 0 then 100 / s else math.huge
	end
	if #path == 0 then
		exits[1] = math.huge
	end
	local entrySide = if entry ~= nil and Transmitters.isSide(entry) then entry else nil
	return { cells = cells, path = path, speeds = speeds, exits = exits, progress = start, entry = entrySide }
end

-- Block k's (1-based) cell of a route.
function TransmitterModel.cell(route: Route, k: number): (number, number, number)
	local i = 3 * (k - 1)
	return route.cells[i + 1], route.cells[i + 2], route.cells[i + 3]
end

--[[
	The way an item on `route` moved when it came into block (x, y, z) (a side), for the route
	that replaces it there (a re-route, a new speed): nil when the block is not on the route or
	the way in is unknown.
]]
function TransmitterModel.entryOf(route: Route, x: number, y: number, z: number): number?
	local cells = route.cells
	for k = 1, #cells // 3 do
		local i = 3 * (k - 1)
		if cells[i + 1] == x and cells[i + 2] == y and cells[i + 3] == z then
			return if k > 1 then route.path[k - 1] else route.entry
		end
	end
	return nil
end

--[[
	The way an item just pulled into a transporter moves (out of the inventory, towards the
	centre), from the transporter's packed `modes` and the sides connected to acceptors: the
	opposite of its one PULL side on an acceptor; nil when it has none or several (unknown).
]]
function TransmitterModel.pullEntry(modes: number, acceptorMask: number): number?
	local found: number? = nil
	for side = 0, 5 do
		if bit32.band(acceptorMask, bit32.lshift(1, side)) ~= 0 and Transmitters.modeOf(modes, side) == PULL then
			if found ~= nil then
				return nil
			end
			found = side
		end
	end
	return if found ~= nil then Transmitters.opposite(found) else nil
end

--[[
	Where an item on `route` is `ticks` after its start (blocks, world coordinates: a cell's centre
	is x + 0.5): the point, the (1-based) block of the route it is in, and whether it has arrived
	(left the last block; it then stays on that block's face).
]]
function TransmitterModel.position(route: Route, ticks: number): (number, number, number, number, boolean)
	local path, exits = route.path, route.exits
	local n = #path
	local t = if ticks == ticks then math.max(ticks, 0) else 0
	if n == 0 then
		local x, y, z = TransmitterModel.cell(route, 1)
		return x + 0.5, y + 0.5, z + 0.5, 1, false
	end
	local k = 1
	while k <= n and t >= exits[k] do
		k += 1
	end
	local arrived = k > n
	local progress
	if arrived then
		k, progress = n, 100
	elseif k == 1 then
		progress = route.progress + t * route.speeds[1]
	else
		progress = 100 - (exits[k] - t) * route.speeds[k]
	end
	progress = math.clamp(progress, 0, 100)
	local x, y, z = TransmitterModel.cell(route, k)
	-- Before the centre along the way it came in (the first block: `entry`, else straight on), then
	-- the way out.
	local side = path[k]
	if progress < 50 then
		side = if k > 1 then path[k - 1] else route.entry or path[1]
	end
	local dx, dy, dz = Transmitters.offset(side)
	local offset = (progress - 50) / 100
	return x + 0.5 + dx * offset, y + 0.5 + dy * offset, z + 0.5 + dz * offset, k, arrived
end

return TransmitterModel

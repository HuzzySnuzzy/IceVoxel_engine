--!strict
--[[
	Mekanism's transmitters (Mekanism 10.x for Minecraft 1.20.1), the parts the server and the
	client share: what each block is, how its sides connect, sided inventories and the numbers.

	  * Logistical Transporters ("item" transmitters, Basic to Ultimate) move items between
	    inventories (chests, furnaces); the Restrictive Transporter is a basic one that routes
	    avoid (path cost 1000 instead of a basic one's 10).
	  * Mechanical Pipes ("fluid" transmitters, Basic to Ultimate) move fluids (Shared/Fluids: water,
	    lava, oil, fuel) between Fluid Tanks and the fluid tanks of machines (Shared/Machines).
	  * Universal Cables ("energy" transmitters, Basic to Ultimate) join energy blocks (Mekanism
	    machines, Shared/Machines) into energy networks; a network moves at most the sum of its
	    cables' capacities per tick (Mekanism's CableTier: 8 000 to 8 192 000 J/t).
	  * Tiers (Transmitters/Tiers): Mekanism's TransporterTier, PipeTier, CableTier and
	    FluidTankTier numbers.

	Pressurized Tubes and Thermodynamic Conductors are left out: the game has no gas or heat.

	Sides are numbered like Minecraft's Direction ordinal: 0 Down, 1 Up, 2 North (-Z), 3 South
	(+Z), 4 West (-X), 5 East (+X) (SIDES, Blocks.DIRECTIONS names). Side s of the block at p is
	its face towards p + offset(s); opposite(s) is the neighbour's side facing back.

	Each side of a transmitter has a connection mode (Mekanism's ConnectionType), which the
	Configurator cycles NORMAL -> PUSH -> PULL -> NONE -> NORMAL (`nextMode`):
	  NORMAL  connects; items and water may leave the network into an acceptor there, and a
	          transporter takes what a furnace or machine there pushes out (`receives`)
	  PUSH    the same, but only out of the network (it never pulls nor receives)
	  PULL    takes from the acceptor there (every PULL_DELAY ticks for transporters, every tick
	          for pipes; only the results of a furnace or machine) and never gives to it
	  NONE    no connection at all
	Universal Cables only know NONE: PUSH and PULL act as NORMAL there (an energy block's part in
	its network is its own: Machines.role).
	The six modes travel and are stored packed in 16 bits, 2 bits a side with side 0 lowest
	(`packModes`, `modeOf`, `withMode`); 0 is all NORMAL.

	Transporters may be coloured with Minecraft's 16 dye colours (1..16, 0 = none; `nextColour`
	is the Configurator's sneak click). Two transmitters connect when they are the same kind,
	neither side is NONE and, for transporters, their colours are compatible (either is
	uncoloured or both are the same); a transmitter connects to an acceptor of its kind (a block
	with item slots, a Fluid Tank or a machine with fluid tanks, an energy block) unless its side
	is NONE. That rule is `connects`, used by the client to draw arms and by the server to build
	networks. An item takes the colour of the transporter that pulled it and only enters
	uncoloured transporters or ones of its colour (`carries`).

	Routes cost Mekanism's getCost per transporter passed (`pathCost`): 10 / 5 / 2.5 / 1 from Basic
	to Ultimate, 1000 for the Restrictive Transporter.

	Sided inventories (insertSlots, extractSlots, canInsert, canExtract, room, insert, available,
	extract) and what furnaces and machines push out on their own (isPlain, ejects, ejectSlots,
	results, takeResults: Mekanism's ejector) come from Transmitters/Inventories, see there.

	Pure: no Roblox APIs, so it runs in tests and on both sides.
]]

local Blocks = require(script.Parent.Blocks)
local Fluids = require(script.Parent.Fluids)
local Machines = require(script.Parent.Machines)
local Inventories = require(script.Inventories)
local Tiers = require(script.Tiers)

export type Slots = Inventories.Slots
export type Tier = Tiers.Tier
-- What a transmitter carries.
export type Kind = "item" | "fluid" | "energy"
-- What a side connects to.
export type Connection = "transmitter" | "acceptor"
export type Colour = { name: string, displayName: string, rgb: { number } }

local Transmitters = {}

--[[ Tiers and constants (Transmitters/Tiers) ]]

-- 1 Basic, 2 Advanced, 3 Elite, 4 Ultimate.
Transmitters.TIERS = Tiers.TIERS
Transmitters.BUCKET = Tiers.BUCKET
Transmitters.TICK_RATE = Tiers.TICK_RATE
Transmitters.PULL_DELAY = Tiers.PULL_DELAY
Transmitters.BLOCK_PROGRESS = Tiers.BLOCK_PROGRESS
Transmitters.TRANSPORTER_COST = Tiers.TRANSPORTER_COST
Transmitters.RESTRICTIVE_COST = Tiers.RESTRICTIVE_COST

--[[ Sides ]]

Transmitters.DOWN = 0
Transmitters.UP = 1
Transmitters.NORTH = 2
Transmitters.SOUTH = 3
Transmitters.WEST = 4
Transmitters.EAST = 5
-- Names of the sides: SIDES[side + 1] (Blocks.DIRECTIONS names).
Transmitters.SIDES = table.freeze({ "Down", "Up", "North", "South", "West", "East" })

local DX = { 0, 0, 0, 0, -1, 1 }
local DY = { -1, 1, 0, 0, 0, 0 }
local DZ = { 0, 0, -1, 1, 0, 0 }
local SIDE_BY_NAME: { [string]: number } = {}
for index, name in Transmitters.SIDES do
	SIDE_BY_NAME[name] = index - 1
	local d = Blocks.DIRECTIONS[name]
	assert(d[1] == DX[index] and d[2] == DY[index] and d[3] == DZ[index], `Side {name} disagrees with Blocks`)
end

local function isSide(side: number): boolean
	return side == 0 or side == 1 or side == 2 or side == 3 or side == 4 or side == 5
end
Transmitters.isSide = isSide

-- The block offset of `side` (dx, dy, dz). Errors on anything but 0..5.
function Transmitters.offset(side: number): (number, number, number)
	assert(isSide(side), "bad side")
	return DX[side + 1], DY[side + 1], DZ[side + 1]
end

-- The side facing back: Down <-> Up, North <-> South, West <-> East.
function Transmitters.opposite(side: number): number
	assert(isSide(side), "bad side")
	return bit32.bxor(side, 1)
end

-- The side of a unit offset (one of the six), else nil.
function Transmitters.sideOf(dx: number, dy: number, dz: number): number?
	for index = 1, 6 do
		if DX[index] == dx and DY[index] == dy and DZ[index] == dz then
			return index - 1
		end
	end
	return nil
end

-- The side named like Blocks.DIRECTIONS ("Down", "East"...), else nil.
function Transmitters.sideNamed(name: string): number?
	return SIDE_BY_NAME[name]
end

function Transmitters.sideName(side: number): string
	return Transmitters.SIDES[side + 1] or "?"
end

--[[ Sizes ]]

-- A transmitter's sizes (pixels): half its core with the frame, and its arms' tube, collar and
-- plate across (client Rendering/TransmitterModel draws them; Blocks/Shapes collides with and
-- aims at the core and the arms as wide as their collars, or plates into acceptors).
export type Sizes = { core: number, arm: number, collar: number, plate: number }
-- Mekanism's large transmitters (transporters and pipes): an 8 pixel core.
Transmitters.LARGE = table.freeze({ core = 4, arm = 6, collar = 7, plate = 10 }) :: Sizes
-- Mekanism's small transmitters (Universal Cables): a 6 pixel core.
Transmitters.SMALL = table.freeze({ core = 3, arm = 4, collar = 5, plate = 8 }) :: Sizes

--[[ Connection modes ]]

Transmitters.MODES = table.freeze({ NORMAL = 0, PUSH = 1, PULL = 2, NONE = 3 })
local NORMAL, PUSH, PULL, NONE = 0, 1, 2, 3
-- Names of the modes: MODE_NAMES[mode + 1].
Transmitters.MODE_NAMES = table.freeze({ "Normal", "Push", "Pull", "None" })
-- Every side NORMAL, packed.
Transmitters.DEFAULT_MODES = 0

local function isMode(mode: number): boolean
	return mode == NORMAL or mode == PUSH or mode == PULL or mode == NONE
end
Transmitters.isMode = isMode

-- The Configurator's next mode: NORMAL -> PUSH -> PULL -> NONE -> NORMAL (Mekanism's order).
function Transmitters.nextMode(mode: number): number
	return if isMode(mode) then (mode + 1) % 4 else NORMAL
end

function Transmitters.modeName(mode: number): string
	return Transmitters.MODE_NAMES[mode + 1] or "?"
end

-- May items or water leave the network into an acceptor through a side in `mode` (NORMAL, PUSH)?
function Transmitters.outputs(mode: number): boolean
	return mode == NORMAL or mode == PUSH
end

-- Does a side in `mode` pull from the acceptor there (PULL)?
function Transmitters.pulls(mode: number): boolean
	return mode == PULL
end

--[[
	Does a transporter side in `mode` take what the furnace or machine there pushes out on its own
	(NORMAL, PULL: Mekanism's canReceiveFrom)? PUSH only gives and NONE is cut.
]]
function Transmitters.receives(mode: number): boolean
	return mode == NORMAL or mode == PULL
end

--[[
	Six modes (modes[side + 1], nil = NORMAL) packed into 16 bits: side s in bits 2s and 2s + 1,
	side 0 lowest. Errors on a mode outside 0..3.
]]
function Transmitters.packModes(modes: { number }): number
	local packed = 0
	for side = 0, 5 do
		local mode = modes[side + 1] or NORMAL
		assert(isMode(mode), "bad mode")
		packed = bit32.replace(packed, mode, side * 2, 2)
	end
	return packed
end

-- The six modes of a packed value: { [side + 1] = mode }.
function Transmitters.unpackModes(packed: number): { number }
	local modes = table.create(6)
	for side = 0, 5 do
		modes[side + 1] = bit32.extract(packed, side * 2, 2)
	end
	return modes
end

-- The mode of `side` in a packed value.
function Transmitters.modeOf(packed: number, side: number): number
	assert(isSide(side), "bad side")
	return bit32.extract(packed, side * 2, 2)
end

-- A packed value with `side` set to `mode`.
function Transmitters.withMode(packed: number, side: number, mode: number): number
	assert(isSide(side) and isMode(mode), "bad side or mode")
	return bit32.replace(packed, mode, side * 2, 2)
end

--[[ Colours ]]

-- Minecraft's dye colours in DyeColor order (their textureDiffuseColor), COLOURS[colour].
Transmitters.COLOURS = table.freeze({
	{ name = "white", displayName = "White", rgb = { 249, 255, 254 } },
	{ name = "orange", displayName = "Orange", rgb = { 249, 128, 29 } },
	{ name = "magenta", displayName = "Magenta", rgb = { 199, 78, 189 } },
	{ name = "light_blue", displayName = "Light Blue", rgb = { 58, 179, 218 } },
	{ name = "yellow", displayName = "Yellow", rgb = { 254, 216, 61 } },
	{ name = "lime", displayName = "Lime", rgb = { 128, 199, 31 } },
	{ name = "pink", displayName = "Pink", rgb = { 243, 139, 170 } },
	{ name = "grey", displayName = "Grey", rgb = { 71, 79, 82 } },
	{ name = "light_grey", displayName = "Light Grey", rgb = { 157, 157, 151 } },
	{ name = "cyan", displayName = "Cyan", rgb = { 22, 156, 156 } },
	{ name = "purple", displayName = "Purple", rgb = { 137, 50, 184 } },
	{ name = "blue", displayName = "Blue", rgb = { 60, 68, 170 } },
	{ name = "brown", displayName = "Brown", rgb = { 131, 84, 50 } },
	{ name = "green", displayName = "Green", rgb = { 94, 124, 22 } },
	{ name = "red", displayName = "Red", rgb = { 176, 46, 38 } },
	{ name = "black", displayName = "Black", rgb = { 29, 29, 33 } },
} :: { Colour })
for _, colour in Transmitters.COLOURS do
	table.freeze(colour.rgb)
	table.freeze(colour)
end
Transmitters.NO_COLOUR = 0
local COLOUR_COUNT = #Transmitters.COLOURS

local function isColour(colour: number): boolean
	return type(colour) == "number" and colour >= 0 and colour <= COLOUR_COUNT and colour == colour // 1
end
Transmitters.isColour = isColour

-- The Configurator's next colour (sneak click): none -> white -> ... -> black -> none.
function Transmitters.nextColour(colour: number): number
	return if isColour(colour) and colour < COLOUR_COUNT then colour + 1 else 0
end

-- "Red", "Light Blue"; "None" for no colour.
function Transmitters.colourName(colour: number): string
	local entry = if colour ~= 0 and isColour(colour) then Transmitters.COLOURS[colour] else nil
	return if entry then entry.displayName else "None"
end

-- { r, g, b } of a colour (0..255), nil for none.
function Transmitters.colourRgb(colour: number): { number }?
	local entry = if colour ~= 0 and isColour(colour) then Transmitters.COLOURS[colour] else nil
	return if entry then entry.rgb else nil
end

-- May transmitters of these colours connect: either is uncoloured, or both are the same?
function Transmitters.coloursMatch(a: number, b: number): boolean
	return a == 0 or b == 0 or a == b
end

--[[
	May an item of `itemColour` (the colour of the transporter that pulled it) enter a transporter
	of `transporterColour`? Mekanism's TransporterStack.canInsertToTransporter: an uncoloured
	transporter takes every item, a coloured one only items of its colour. Unlike `coloursMatch`
	this is one-way: an uncoloured item never enters a coloured transporter, though the two
	transporters are connected.
]]
function Transmitters.carries(transporterColour: number, itemColour: number): boolean
	return transporterColour == 0 or transporterColour == itemColour
end

--[[ Blocks ]]

-- Per block id, from BlockList `transmitter` / `tank`.
local kinds: { [number]: Kind } = {}
local tierIndex: { [number]: number } = {}
local restrictive: { [number]: boolean } = {}
local tanks: { [number]: boolean } = {}
local tankCapacities: { [number]: number } = {}
for id = 0, Blocks.count - 1 do
	local def = Blocks.get(id)
	local transmitter = def.transmitter
	if transmitter then
		local kind = transmitter.kind
		kinds[id] = if kind == "item" then "item" elseif kind == "energy" then "energy" else "fluid"
		tierIndex[id] = transmitter.tier
		restrictive[id] = transmitter.restrictive == true
	elseif def.tank then
		tanks[id] = true
		tierIndex[id] = def.tank.tier
		tankCapacities[id] = def.tank.capacity
	end
end

-- What a transmitter carries ("item", "fluid" or "energy"), nil for every other block.
function Transmitters.kindOf(block: number): Kind?
	return kinds[block]
end

function Transmitters.isTransmitter(block: number): boolean
	return kinds[block] ~= nil
end

-- The sizes of the transmitter `block` (SMALL for Universal Cables, else LARGE).
function Transmitters.sizes(block: number?): Sizes
	return if block and kinds[block] == "energy" then Transmitters.SMALL else Transmitters.LARGE
end

-- Is it the Restrictive Transporter (path cost RESTRICTIVE_COST)?
function Transmitters.isRestrictive(block: number): boolean
	return restrictive[block] == true
end

function Transmitters.isTank(block: number): boolean
	return tanks[block] == true
end

-- The tier (1..4) of a transmitter or tank, else nil.
function Transmitters.tierOf(block: number): number?
	return tierIndex[block]
end

-- The TIERS entry of a transmitter or tank, else nil.
function Transmitters.tier(block: number): Tier?
	local index = tierIndex[block]
	return if index then Tiers.TIERS[index] else nil
end

-- Items a transporter takes per pull, mB per tick a pipe takes from a tank; 0 for other blocks.
function Transmitters.pullAmount(block: number): number
	local kind, index = kinds[block], tierIndex[block]
	if kind == "item" then
		return Tiers.TIERS[index].transporterPull
	elseif kind == "fluid" then
		return Tiers.TIERS[index].pipePull
	end
	return 0
end

-- Progress per tick of an item in a transporter (BLOCK_PROGRESS = one block); 0 for others.
function Transmitters.speed(block: number): number
	return if kinds[block] == "item" then Tiers.TIERS[tierIndex[block]].transporterSpeed else 0
end

--[[
	What passing a transporter costs a route (Mekanism's getCost, the edge weight of its
	TransporterPathfinder): the Ultimate tier's speed over the transporter's, so Basic 10, Advanced
	5, Elite 2.5, Ultimate 1 (TRANSPORTER_COST), and RESTRICTIVE_COST (1000) for a Restrictive
	Transporter; math.huge for anything that is no transporter.
]]
local ULTIMATE_SPEED = Tiers.TIERS[#Tiers.TIERS].transporterSpeed
function Transmitters.pathCost(block: number): number
	if kinds[block] ~= "item" then
		return math.huge
	end
	return if restrictive[block]
		then Tiers.RESTRICTIVE_COST
		else ULTIMATE_SPEED / Tiers.TIERS[tierIndex[block]].transporterSpeed
end

-- mB a mechanical pipe adds to its network's buffer; 0 for other blocks.
function Transmitters.pipeCapacity(block: number): number
	return if kinds[block] == "fluid" then Tiers.TIERS[tierIndex[block]].pipeCapacity else 0
end

-- J per tick a Universal Cable adds to its energy network's throughput; 0 for other blocks.
function Transmitters.cableCapacity(block: number): number
	return if kinds[block] == "energy" then Tiers.TIERS[tierIndex[block]].cableCapacity else 0
end

-- What a transmitter adds to its network: a pipe's mB, a cable's J per tick; 0 for others.
function Transmitters.capacity(block: number): number
	local kind = kinds[block]
	if kind == "fluid" then
		return Tiers.TIERS[tierIndex[block]].pipeCapacity
	elseif kind == "energy" then
		return Tiers.TIERS[tierIndex[block]].cableCapacity
	end
	return 0
end

-- mB a fluid tank holds; 0 for other blocks.
function Transmitters.tankCapacity(block: number): number
	return tankCapacities[block] or 0
end

-- mB per tick a fluid tank gives out at most; 0 for other blocks.
function Transmitters.tankOutput(block: number): number
	return if tanks[block] then Tiers.TIERS[tierIndex[block]].tankOutput else 0
end

-- Does the block keep items transporters connect to (a chest or a furnace: `container` > 0)?
function Transmitters.isItemAcceptor(block: number): boolean
	return Inventories.isInventory(block)
end

-- Does the block hold fluid pipes connect to (a Fluid Tank, or a machine with fluid tanks:
-- Machines.hasTanks)?
function Transmitters.isFluidAcceptor(block: number): boolean
	return tanks[block] == true or Machines.hasTanks(block)
end

-- Does the block hold energy Universal Cables connect to (a Mekanism machine, Shared/Machines)?
function Transmitters.isEnergyAcceptor(block: number): boolean
	return Machines.hasEnergy(block)
end

-- Is `block` an acceptor for transmitters of `kind`?
function Transmitters.isAcceptor(kind: Kind, block: number): boolean
	if kind == "item" then
		return Inventories.isInventory(block)
	elseif kind == "energy" then
		return Machines.hasEnergy(block)
	end
	return tanks[block] == true or Machines.hasTanks(block)
end

--[[
	What one side of a transmitter connects to (Mekanism's canConnectMutual): `selfBlock` with
	`selfMode` on that side and colour `selfColour`, next to `otherBlock`, whose side facing back
	has `otherMode` and whose colour is `otherColour` (both only matter for transmitters; nil:
	NORMAL and none).
	  "transmitter"  the same kind of transmitter (any tier), neither side NONE, colours compatible
	                 (transporters only: Mekanism's pipes have no colour, so theirs is ignored)
	  "acceptor"     an inventory (item), a Fluid Tank or a machine with fluid tanks (fluid) or an
	                 energy block (energy), and the side is not NONE
	  nil            anything else, and every side of a block that is no transmitter
]]
function Transmitters.connects(
	selfBlock: number,
	selfMode: number,
	selfColour: number,
	otherBlock: number,
	otherMode: number?,
	otherColour: number?
): Connection?
	local kind: Kind? = kinds[selfBlock]
	if kind == nil or selfMode == NONE then
		return nil
	end
	local otherKind = kinds[otherBlock]
	if otherKind ~= nil then
		if
			otherKind == kind
			and (otherMode or NORMAL) ~= NONE
			and (kind ~= "item" or Transmitters.coloursMatch(selfColour, otherColour or 0))
		then
			return "transmitter"
		end
		return nil
	end
	if Transmitters.isAcceptor(kind :: Kind, otherBlock) then
		return "acceptor"
	end
	return nil
end

--[[
	All six sides of the transmitter `block` at (x, y, z) with packed `modes` and `colour`, as two
	bit masks (bit `side` set): sides connected to transmitters and sides connected to acceptors.
	`getBlock(x, y, z)` answers nil for unknown (unloaded) cells, which connect to nothing;
	`getState(x, y, z)` gives a neighbouring transmitter's packed modes and colour (0, 0 when it
	has none). The client draws arms from this and the server walks networks with it.
]]
function Transmitters.connections(
	block: number,
	modes: number,
	colour: number,
	x: number,
	y: number,
	z: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	getState: (x: number, y: number, z: number) -> (number, number)
): (number, number)
	local transmitters, acceptors = 0, 0
	if kinds[block] == nil then
		return 0, 0
	end
	for side = 0, 5 do
		local selfMode = bit32.extract(modes, side * 2, 2)
		if selfMode ~= NONE then
			local nx, ny, nz = x + DX[side + 1], y + DY[side + 1], z + DZ[side + 1]
			local other = getBlock(nx, ny, nz)
			if other ~= nil then
				local otherMode, otherColour = NORMAL, 0
				if kinds[other] ~= nil then
					local otherModes, theirColour = getState(nx, ny, nz)
					otherMode = bit32.extract(otherModes or 0, bit32.bxor(side, 1) * 2, 2)
					otherColour = theirColour or 0
				end
				local connection = Transmitters.connects(block, selfMode, colour, other, otherMode, otherColour)
				if connection == "transmitter" then
					transmitters = bit32.bor(transmitters, bit32.lshift(1, side))
				elseif connection == "acceptor" then
					acceptors = bit32.bor(acceptors, bit32.lshift(1, side))
				end
			end
		end
	end
	return transmitters, acceptors
end

--[[ Fluids ]]

-- Fluid ids (Protocol `Tanks` / `Transmitters`, the server's buffers): Shared/Fluids' (0 none,
-- 1 water, 2 lava, 3 oil, 4 fuel), here for the code that knew only water.
Transmitters.FLUIDS = table.freeze({
	NONE = Fluids.NONE,
	WATER = Fluids.WATER,
	LAVA = Fluids.LAVA,
	OIL = Fluids.OIL,
	FUEL = Fluids.FUEL,
})
local fluidNames: { string } = {}
for id, fluid in Fluids.list do
	fluidNames[id] = fluid.displayName
end
-- FLUID_NAMES[id]: "Water", "Lava", "Oil", "Fuel" (Fluids.name).
Transmitters.FLUID_NAMES = table.freeze(fluidNames)

-- "Lava"; "Empty" for none and unknown ids (Fluids.name).
Transmitters.fluidName = Fluids.name

--[[
	How full something is, as a byte (Protocol `Transmitters.fluid`): 0 empty, 255 full, and at
	least 1 while anything is in it.
]]
function Transmitters.fillLevel(amount: number, capacity: number): number
	if amount ~= amount or amount <= 0 or capacity ~= capacity or capacity <= 0 then
		return 0
	elseif amount >= capacity then
		return 255
	end
	return math.clamp(math.ceil(amount / capacity * 255), 1, 255)
end

-- About how much a fill byte stands for (mB, rounded), back from `fillLevel`.
function Transmitters.fillAmount(level: number, capacity: number): number
	return math.round(math.clamp(level, 0, 255) / 255 * capacity)
end

--[[ Sided item inventories (Transmitters/Inventories) ]]

Transmitters.insertSlots = Inventories.insertSlots
Transmitters.extractSlots = Inventories.extractSlots
Transmitters.canInsert = Inventories.canInsert
Transmitters.canExtract = Inventories.canExtract
Transmitters.room = Inventories.room
Transmitters.insert = Inventories.insert
Transmitters.available = Inventories.available
Transmitters.extract = Inventories.extract
Transmitters.isPlain = Inventories.isPlain
Transmitters.ejects = Inventories.ejects
Transmitters.ejectSlots = Inventories.ejectSlots
Transmitters.results = Inventories.results
Transmitters.takeResults = Inventories.takeResults

return Transmitters

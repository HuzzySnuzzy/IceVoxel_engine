--!strict
--[[
	The boxes a block collides with and is aimed at where it stands (Minecraft's collision and
	outline VoxelShapes), for what Blocks alone can't tell: a Mekanism transmitter's depend on its
	neighbours. Pure: player, mob and item physics (Shared/Movement/Hull's SolidAt), mobs' line of
	sight and explosions (`sight`) and the client's aim use it.

	  collisionAt  Blocks.collision (true: a full cell; false: nothing; else boxes in the cell's
	               units: a door's panel, a fence's post and arms 1.5 blocks high), and for a
	               transmitter its core and an arm towards every side it connects to
	               (Transmitters.connections with every side NORMAL and no colour: modes and
	               colours are the server's and the client renderer's, so a side configured to NONE
	               still collides). Arms are as wide as their collars, into acceptors as their
	               plates (Transmitters.sizes), as the client aims at them (TransmitterModel).
	  transmitterBoxes  those boxes for given connection masks (the client's aim passes the
	               renderer's real ones).
	  flat         a shape as one list of numbers, six per box (VoxelRaycast outlines).
	  sight        what blocks a line of sight (Minecraft's ClipContext.Block.COLLIDER): blocks
	               that collide, by their collision boxes; a closed door's panel blocks it, an open
	               door beside the line does not.
]]

local Blocks = require(script.Parent)
local Transmitters = require(script.Parent.Parent.Transmitters)

export type Box = Blocks.CollisionBox
export type Shape = { Box }

local Shapes = {}

local transmitterLut = buffer.create(Blocks.count)
for id = 0, Blocks.count - 1 do
	if Transmitters.isTransmitter(id) then
		buffer.writeu8(transmitterLut, id, 1)
	end
end

local function zeroState(_x: number, _y: number, _z: number): (number, number)
	return 0, 0
end

-- Boxes per sizes and masks (shapes are shared and never changed).
local transmitterCache: { [string]: Shape } = {}

--[[
	A transmitter's boxes (cell units): its core, and an arm out to the cell's face on every side
	in `transmitters` (bit `side`: Transmitters' sides) as wide as its collar, and in `acceptors`
	as its plate. `block` gives the sizes (Transmitters.sizes).
]]
function Shapes.transmitterBoxes(block: number, transmitters: number, acceptors: number): Shape
	local sizes = Transmitters.sizes(block)
	local key = `{sizes.core}|{transmitters}|{acceptors}`
	local cached = transmitterCache[key]
	if cached then
		return cached
	end
	local core = sizes.core / 16
	local boxes: Shape = {
		table.freeze({
			minX = 0.5 - core,
			minY = 0.5 - core,
			minZ = 0.5 - core,
			maxX = 0.5 + core,
			maxY = 0.5 + core,
			maxZ = 0.5 + core,
		}),
	}
	for side = 0, 5 do
		local bit = bit32.lshift(1, side)
		local plate = bit32.band(acceptors, bit) ~= 0
		if plate or bit32.band(transmitters, bit) ~= 0 then
			local half = (if plate then sizes.plate else sizes.collar) / 2 / 16
			local lo = { 0.5 - half, 0.5 - half, 0.5 - half }
			local hi = { 0.5 + half, 0.5 + half, 0.5 + half }
			local sx, sy, sz = Transmitters.offset(side)
			local s = { sx, sy, sz }
			for k = 1, 3 do
				if s[k] > 0 then
					lo[k], hi[k] = 0.5 + core, 1
				elseif s[k] < 0 then
					lo[k], hi[k] = 0, 0.5 - core
				end
			end
			table.insert(
				boxes,
				table.freeze({ minX = lo[1], minY = lo[2], minZ = lo[3], maxX = hi[1], maxY = hi[2], maxZ = hi[3] })
			)
		end
	end
	local shape = table.freeze(boxes)
	transmitterCache[key] = shape
	return shape
end

--[[
	What the movement hull bumps into in `block`'s cell at (x, y, z) (Hull's SolidAt answer; see
	the header). `getBlock` answers nil for unknown (unloaded) cells, which a transmitter does not
	connect to.
]]
function Shapes.collisionAt(
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number,
	block: number
): boolean | Shape
	if buffer.readu8(transmitterLut, block) == 1 then
		local transmitters, acceptors =
			Transmitters.connections(block, Transmitters.DEFAULT_MODES, 0, x, y, z, getBlock, zeroState)
		return Shapes.transmitterBoxes(block, transmitters, acceptors)
	end
	return Blocks.collision(block)
end

-- Is the block a transmitter (its shape depends on its neighbours: `collisionAt`)?
function Shapes.isDynamic(block: number): boolean
	return block >= 0 and block < Blocks.count and buffer.readu8(transmitterLut, block) == 1
end

local flats: { [Shape]: { number } } = setmetatable({}, { __mode = "k" }) :: any

-- A shape's boxes as one list, six numbers each (minX, minY, minZ, maxX, maxY, maxZ).
function Shapes.flat(shape: Shape): { number }
	local cached = flats[shape]
	if cached then
		return cached
	end
	local list: { number } = {}
	for _, box in shape do
		table.insert(list, box.minX)
		table.insert(list, box.minY)
		table.insert(list, box.minZ)
		table.insert(list, box.maxX)
		table.insert(list, box.maxY)
		table.insert(list, box.maxZ)
	end
	table.freeze(list)
	flats[shape] = list
	return list
end

type GetBlock = (x: number, y: number, z: number) -> number?
type Outline = (id: number, x: number, y: number, z: number) -> { number }?

local function stops(id: number): boolean
	return Blocks.collision(id) ~= false or buffer.readu8(transmitterLut, id) == 1
end

-- Each world's outline function (kept while its getBlock lives).
local outlines: { [GetBlock]: Outline } = setmetatable({}, { __mode = "k" }) :: any

--[[
	The block test and outline for a ray that blocks stop by their collision boxes (VoxelRaycast's
	`isTarget` and `outline`): Minecraft's ClipContext COLLIDER, as mobs' line of sight and
	explosions' exposure use it.
]]
function Shapes.sight(getBlock: GetBlock): ((id: number) -> boolean, Outline)
	local outline = outlines[getBlock]
	if outline == nil then
		outline = function(id: number, x: number, y: number, z: number): { number }?
			local shape = Shapes.collisionAt(getBlock, x, y, z, id)
			if type(shape) == "table" then
				return Shapes.flat(shape)
			end
			return nil
		end
		outlines[getBlock] = outline
	end
	return stops, outline :: Outline
end

return Shapes

--!strict
--[[
	Where plants are drawn in their cell (Minecraft's OffsetType).

	Minecraft draws grass, ferns and flowers a little off the centre of their cell, by a hash of the
	block position, so a field of them is no grid. Plants here (BlockList `scatter`) are offset the
	same way and, since they are a few boxes rather than crossed quads that look alike from every
	side, also turned about the vertical axis, so neighbouring tufts differ:

	  of(x, y, z)              -> dx, dz, yaw: the offset in pixels (1/16 block, each within
	                              +-MAX_OFFSET, in Minecraft's 16 steps) and the turn in radians
	                              (0 .. 2 pi, in 64 steps), from the world block position alone
	                              (Util/Hash; like Minecraft's, it does not depend on the seed)
	  at(appearance, x, y, z)  -> the same for a cell drawn with `appearance`: the upper half of a
	                              tall plant uses its lower half's position (y - 1), so both halves
	                              line up; plants that face one way (the sunflower faces east, as
	                              in Minecraft, which turns no plant) are offset but not turned
	  keepsFacing(appearance)  -> true for those plants that are never turned
	  turn(x, z, yaw)          -> (x, z) turned by `yaw` about the vertical axis, the way
	                              CFrame.Angles(0, yaw, 0) turns a vector

	Rendering/ChunkRenderer draws each box of a scattered cell at the cell's centre plus
	(dx, 0, dz), turned by yaw about the cell's vertical axis, then by the box's own rotation.
	BlockList keeps every plant's boxes inside its outline whichever way they turn, and within a
	pixel of the cell after the offset. The outline players aim at stays put (Minecraft's moves
	with the plant); the offset is small, so it still sits around most of the plant.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Hash = require(script.Parent.Parent.Util.Hash)

local Scatter = {}

-- Largest offset along X and Z, in pixels (Minecraft's is 4 for grass and flowers).
Scatter.MAX_OFFSET = 3

local SALT = Hash.string("Scatter")
local TURNS = 64
local TAU = 2 * math.pi

-- Plants that face one way and are never turned (by block name).
local FACING = { "Sunflower", "SunflowerTop" }

-- Per appearance id: 1 when its cells use the position below (upper halves), and when they keep
-- their facing.
local COUNT = #Blocks.appearances
local upperLut = buffer.create(COUNT + 1)
local facingLut = buffer.create(COUNT + 1)
for _, appearance in Blocks.appearances do
	buffer.writeu8(upperLut, appearance.id, if appearance.upperHalf then 1 else 0)
end
for _, name in FACING do
	buffer.writeu8(facingLut, Blocks.get(Blocks.id[name]).appearance, 1)
end

-- The offset (pixels) and turn (radians) of a plant at world block position (x, y, z).
function Scatter.of(x: number, y: number, z: number): (number, number, number)
	local h = Hash.hash3(SALT, x, y, z)
	local max = Scatter.MAX_OFFSET
	local dx = (h % 16) / 15 * 2 * max - max
	local dz = (h // 16 % 16) / 15 * 2 * max - max
	local yaw = (h // 256 % TURNS) / TURNS * TAU
	return dx, dz, yaw
end

-- Does `appearance` keep its facing (never turned)?
function Scatter.keepsFacing(appearance: number): boolean
	return appearance > 0 and appearance <= COUNT and buffer.readu8(facingLut, appearance) == 1
end

-- The offset and turn of a cell drawn with `appearance` at (x, y, z): upper halves of tall plants
-- take their lower half's, and plants that face one way are not turned.
function Scatter.at(appearance: number, x: number, y: number, z: number): (number, number, number)
	local upper = appearance > 0 and appearance <= COUNT and buffer.readu8(upperLut, appearance) == 1
	local dx, dz, yaw = Scatter.of(x, if upper then y - 1 else y, z)
	return dx, dz, if Scatter.keepsFacing(appearance) then 0 else yaw
end

-- (x, z) turned by `yaw` radians about the vertical axis, as CFrame.Angles(0, yaw, 0) turns it.
function Scatter.turn(x: number, z: number, yaw: number): (number, number)
	local c, s = math.cos(yaw), math.sin(yaw)
	return x * c + z * s, -x * s + z * c
end

return Scatter

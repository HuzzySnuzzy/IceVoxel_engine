--!strict
--[[
	Vegetation builders. Each builder gets the writer, the position of the first air block above
	the ground and a seeded RNG.

	Builders must consume the RNG the same way no matter which chunk is being generated (never
	branch on `w.get` results before drawing random numbers) — every chunk the tree overlaps runs
	the builder and they all have to agree on its shape.

	Shapes are kept "box friendly": canopies are stacks of squares (wide ones lose their corners)
	and identical layers sit on top of each other, so the greedy mesher turns a whole tree into a
	handful of parts. Every leaf block costs nothing extra; every irregular edge does.
]]

local Blocks = require(script.Parent.Parent.Parent.Blocks)
local Hash = require(script.Parent.Parent.Parent.Util.Hash)
local Writer = require(script.Parent.Writer)

type Writer = Writer.Writer
type Rng = Hash.Rng

local id = Blocks.id
local abs = math.abs

local Trees = {}

-- Square of leaves; squares wider than 3x3 lose their four corners.
local function leaves(w: Writer, x: number, y: number, z: number, radius: number, leaf: number)
	local trim = radius >= 2
	for dz = -radius, radius do
		for dx = -radius, radius do
			if not (trim and abs(dx) == radius and abs(dz) == radius) then
				w.set(x + dx, y, z + dz, leaf)
			end
		end
	end
end

local function trunk(w: Writer, x: number, y: number, z: number, height: number, log: number)
	for i = 0, height - 1 do
		w.force(x, y + i, z, log)
	end
end

-- Broadleaf tree: two wide layers under two narrow ones (5 parts).
local function broadleaf(w: Writer, x: number, y: number, z: number, height: number, log: number, leaf: number)
	local top = y + height
	leaves(w, x, top - 3, z, 2, leaf)
	leaves(w, x, top - 2, z, 2, leaf)
	leaves(w, x, top - 1, z, 1, leaf)
	leaves(w, x, top, z, 1, leaf)
	trunk(w, x, y, z, height, log)
end

function Trees.oak(w: Writer, x: number, y: number, z: number, rng: Rng)
	broadleaf(w, x, y, z, rng:int(4, 6), id.OakLog, id.OakLeaves)
end

function Trees.birch(w: Writer, x: number, y: number, z: number, rng: Rng)
	broadleaf(w, x, y, z, rng:int(5, 7), id.BirchLog, id.BirchLeaves)
end

-- Conifer: tiers getting narrower towards a one block tip.
function Trees.spruce(w: Writer, x: number, y: number, z: number, rng: Rng)
	local height = rng:int(7, 10)
	local width = rng:int(2, 3)
	local leaf = id.SpruceLeaves
	local top = y + height

	w.set(x, top, z, leaf)
	local ly = top - 1
	-- Narrowest tier on top, widest at the bottom; each tier is two layers tall.
	for radius = 1, width do
		for _ = 1, 2 do
			if ly >= y + 2 then
				leaves(w, x, ly, z, radius, leaf)
				ly -= 1
			end
		end
	end
	trunk(w, x, y, z, height, id.SpruceLog)
end

-- Trunk that leans to one side and ends in a flat, wide canopy.
function Trees.acacia(w: Writer, x: number, y: number, z: number, rng: Rng)
	local height = rng:int(5, 7)
	local dir = rng:int(0, 3)
	local dx = if dir == 0 then 1 elseif dir == 1 then -1 else 0
	local dz = if dir == 2 then 1 elseif dir == 3 then -1 else 0
	local bendAt = height - rng:int(1, 2)
	local log, leaf = id.AcaciaLog, id.AcaciaLeaves

	local tx, tz = x, z
	for i = 0, height - 1 do
		if i >= bendAt then
			tx += dx
			tz += dz
		end
		w.force(tx, y + i, tz, log)
	end
	local top = y + height
	leaves(w, tx, top, tz, 3, leaf)
	leaves(w, tx, top + 1, tz, 1, leaf)
end

-- Tall tree with a big crown.
function Trees.jungle(w: Writer, x: number, y: number, z: number, rng: Rng)
	local height = rng:int(8, 12)
	local leaf = id.JungleLeaves
	local top = y + height
	leaves(w, x, top - 2, z, 3, leaf)
	leaves(w, x, top - 1, z, 3, leaf)
	leaves(w, x, top, z, 2, leaf)
	leaves(w, x, top + 1, z, 1, leaf)
	trunk(w, x, y, z, height, id.JungleLog)
end

function Trees.cactus(w: Writer, x: number, y: number, z: number, rng: Rng)
	local height = rng:int(1, 3)
	for i = 0, height - 1 do
		w.set(x, y + i, z, id.Cactus)
	end
end

return Trees

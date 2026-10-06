--!strict
--[[
	Chooses which chunks (quadtree nodes) should be visible around a point.

	The world is tiled with root nodes of the coarsest level. A node at level L covers
	ChunkSize * 2^L blocks and is split into its four children while the viewer is closer than
	`SplitDistance * nodeSize`. The leaves of that recursion are the chunks to display; they never
	overlap and leave no gaps, and detail falls off smoothly with distance. Nodes entirely beyond the
	view distance are left out (the area they cover is simply not drawn).

	Hysteresis: a node that was a leaf in the previous selection needs the viewer a bit closer
	before it splits, so standing on a boundary does not rebuild chunks back and forth. (So full
	detail ends up to 15% short of the split distance ahead of a moving viewer.)

	View and split distance come from Config.Lod; `configure` changes them (the client uses this
	for its device preset).

	Caves only exist in full detail chunks, so underground the full detail range is what limits how
	far caves are seen. While the client's cave view is active with the camera shut in
	(`select`'s `underground`: below the terrain surface in a cave or under rock, not at the open
	bottom of a pit or a ravine: Streaming/CaveReach.enclosed; plus a few seconds after that
	ends, which the streamer decides), level 1 nodes split with
	Config.Lod.UndergroundSplitDistanceL1 instead of SplitDistanceL1, so full detail reaches
	further out (radius about 2 x that, in chunks). Coarser
	levels are unchanged. Level 1's hysteresis holds within one mode only: the first selection
	after the cave view starts splits every level 1 node within the new distance, instead of
	keeping the leaves of the selection above ground short of it.

	Plants (`drawsFoliage`): every box of a plant is a part, so full detail chunks draw theirs only
	within Config.Lod.FoliageDistance (`setFoliageDistance` for the device preset), and only while
	Config.Render.Foliage is on. A chunk drawing them keeps them until it is half a chunk further
	(hysteresis again: walking along the edge does not remesh chunks back and forth).

	`version` changes with every `configure` / `setFoliageDistance` (the settings menu), so the
	streamer knows to select again even if the viewer did not move.

	Seams (`coarserSides`): a full detail chunk is meshed knowing the level of the coarser node on
	each side, if any. When the selection changes, only chunks next to a coarse node that appeared
	or went away can see a different answer (`seamsAffected`).
]]

local Config = require(script.Parent.Parent.Config)
local Coords = require(script.Parent.Coords)

local SIZE = Config.ChunkSize
local MAX_LEVEL = Config.Lod.Levels - 1
local HYSTERESIS = 0.85
-- Blocks beyond the foliage distance a chunk that draws plants keeps them.
local FOLIAGE_HYSTERESIS = SIZE / 2

local view = Config.Lod.ViewDistance
local split = Config.Lod.SplitDistance
local splitL1 = Config.Lod.SplitDistanceL1 or split
local undergroundL1 = math.max(splitL1, Config.Lod.UndergroundSplitDistanceL1 or splitL1)
local foliage = Config.Lod.FoliageDistance
local version = 0

local LodTree = {}

LodTree.MAX_LEVEL = MAX_LEVEL

-- Border sides in GreedyMesher order: -X, +X, -Z, +Z.
local SIDES = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local NO_COARSER = table.freeze({ 0, 0, 0, 0 })
LodTree.NO_COARSER = NO_COARSER

--[[
	Sets the view distance (blocks) and split distances (node sizes; level 1 may differ, and differ
	again while the cave view is active: never less than `splitDistanceL1`) used by `select`.
]]
function LodTree.configure(
	viewDistance: number,
	splitDistance: number,
	splitDistanceL1: number?,
	undergroundSplitDistanceL1: number?
)
	assert(viewDistance > 0 and splitDistance >= 1, "invalid LOD distances")
	view, split = viewDistance, splitDistance
	splitL1 = splitDistanceL1 or splitDistance
	assert(splitL1 >= 1, "invalid LOD distances")
	undergroundL1 = math.max(splitL1, undergroundSplitDistanceL1 or splitL1)
	version += 1
end

-- Changes whenever the distances or the foliage distance are set.
function LodTree.version(): number
	return version
end

-- The level 1 split distance `select` uses (node sizes), with the cave view active or not.
function LodTree.splitDistanceL1(underground: boolean?): number
	return if underground then undergroundL1 else splitL1
end

function LodTree.viewDistance(): number
	return view
end

LodTree.FOLIAGE_HYSTERESIS = FOLIAGE_HYSTERESIS

-- Sets how far full detail chunks draw their plants (blocks; Config.Lod.FoliageDistance).
function LodTree.setFoliageDistance(distance: number)
	assert(distance >= 0, "invalid foliage distance")
	if distance ~= foliage then
		foliage = distance
		version += 1
	end
end

function LodTree.foliageDistance(): number
	return foliage
end

function LodTree.nodeSize(level: number): number
	return SIZE * bit32.lshift(1, level)
end

-- Horizontal distance (blocks) from (x, z) to the square of a node; 0 inside it.
function LodTree.distance(level: number, nx: number, nz: number, x: number, z: number): number
	local size = SIZE * bit32.lshift(1, level)
	local minX, minZ = nx * size, nz * size
	local dx = math.max(minX - x, 0, x - (minX + size))
	local dz = math.max(minZ - z, 0, z - (minZ + size))
	return math.sqrt(dx * dx + dz * dz)
end

--[[
	Does node (level, nx, nz) draw its plants for the viewer at (x, z)? Full detail chunks closer
	than the foliage distance do, while Config.Render.Foliage is on; one that `drawn` them keeps
	them up to FOLIAGE_HYSTERESIS blocks further.
]]
function LodTree.drawsFoliage(level: number, nx: number, nz: number, x: number, z: number, drawn: boolean?): boolean
	if level ~= 0 or not Config.Render.Foliage then
		return false
	end
	local reach = if drawn then foliage + FOLIAGE_HYSTERESIS else foliage
	return LodTree.distance(level, nx, nz, x, z) < reach
end

--[[ Seams ]]

-- Levels of the coarser nodes next to each side of node (level, nx, nz) in `desired` (0: same or
-- finer). NO_COARSER (frozen) when there are none.
function LodTree.coarserSides(desired: { [number]: number }, level: number, nx: number, nz: number): { number }
	local out: { number }? = nil
	for i, side in SIDES do
		local x, z = nx + side[1], nz + side[2]
		for coarse = level + 1, MAX_LEVEL do
			local f = bit32.lshift(1, coarse - level)
			if desired[Coords.nodeKey(coarse, x // f, z // f)] then
				if out == nil then
					out = { 0, 0, 0, 0 }
				end
				(out :: { number })[i] = coarse
				break
			end
		end
	end
	return out or NO_COARSER
end

--[[
	Full detail chunks of `desired` whose `coarserSides` may have changed because the coarser nodes
	in `changed` (key -> level; appeared or went away) did: the chunks just outside each one's
	square, on its four sides. (Chunks inside such a square are new to the selection.)
]]
function LodTree.seamsAffected(changed: { [number]: number }, desired: { [number]: number }): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for key, level in changed do
		if level >= 1 then
			local _, nx, nz = Coords.decodeNodeKey(key)
			local n = bit32.lshift(1, level)
			local x0, z0 = nx * n, nz * n
			local x1, z1 = x0 + n - 1, z0 + n - 1
			for i = 0, n - 1 do
				for _, cell in { { x0 - 1, z0 + i }, { x1 + 1, z0 + i }, { x0 + i, z0 - 1 }, { x0 + i, z1 + 1 } } do
					local chunk = Coords.chunkKey(cell[1], cell[2])
					if desired[chunk] == 0 then
						out[chunk] = true
					end
				end
			end
		end
	end
	return out
end

--[[
	Returns { [nodeKey] = level } for the viewer at block coordinates (x, z).
	`previous` is the result of the last call (optional, enables hysteresis). `underground`: the
	cave view is active with the camera shut in, so full detail reaches further
	(UndergroundSplitDistanceL1); `previousUnderground`: it was for `previous` (level 1 keeps no
	hysteresis across a change).
]]
function LodTree.select(
	x: number,
	z: number,
	previous: { [number]: number }?,
	underground: boolean?,
	previousUnderground: boolean?
): { [number]: number }
	local out: { [number]: number } = {}
	local distance = LodTree.distance
	local l1 = if underground then undergroundL1 else splitL1
	local l1Hysteresis = (underground == true) == (previousUnderground == true)

	local function visit(level: number, nx: number, nz: number)
		local d = distance(level, nx, nz, x, z)
		if d > view then
			return
		end
		if level > 0 then
			local threshold = (if level == 1 then l1 else split) * SIZE * bit32.lshift(1, level)
			if previous and previous[Coords.nodeKey(level, nx, nz)] and (level ~= 1 or l1Hysteresis) then
				threshold *= HYSTERESIS
			end
			if d < threshold then
				local cx, cz = nx * 2, nz * 2
				visit(level - 1, cx, cz)
				visit(level - 1, cx + 1, cz)
				visit(level - 1, cx, cz + 1)
				visit(level - 1, cx + 1, cz + 1)
				return
			end
		end
		out[Coords.nodeKey(level, nx, nz)] = level
	end

	local rootSize = LodTree.nodeSize(MAX_LEVEL)
	local reach = math.ceil(view / rootSize)
	local rx, rz = x // rootSize, z // rootSize
	for nz = rz - reach, rz + reach do
		for nx = rx - reach, rx + reach do
			visit(MAX_LEVEL, nx, nz)
		end
	end
	return out
end

return LodTree

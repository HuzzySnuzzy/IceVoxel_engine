--!strict
--[[
	How far around an underground camera caves are revealed (meshed with their walls; elsewhere cave
	air counts as rock, see Blocks.cullLutHiddenCaves).

	A tunnel needs little, but a big cavern (the Underlands under the highest mountains are hundreds
	of blocks across) would show rock a few dozen blocks away. So `probe` casts rays through the
	loaded blocks, sideways and upwards (the camera is usually just above a floor, which says nothing
	about the size of the space), and takes the median of how far they get: open space all around
	reaches far, a single long tunnel or shaft does not. A `Tracker` turns that into a reveal
	radius in whole sections, growing at once but shrinking only after the open space stayed smaller
	for a while, so the revealed sections do not churn while the camera moves.

	Also pure, for the streamer: which sections are revealed (`reveals`: section centres within the
	reach of the camera), which sides of a revealed section need a cave cap (`capMask`: the
	neighbours that are not revealed full detail sections), and a `hold` that keeps the cave view's
	extended full detail range (Lod.UndergroundSplitDistanceL1) for a few seconds after the camera
	comes up.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

local SIZE = Config.ChunkSize
local SECTION = Config.SectionHeight
local SECTIONS = Config.WorldHeight // SECTION
-- Border sides in GreedyMesher order: -X, +X, -Z, +Z.
local SIDES = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

-- Directions to the neighbouring cells at the same height or above (17), normalised.
local DIRECTIONS: { { number } } = {}
for x = -1, 1 do
	for y = 0, 1 do
		for z = -1, 1 do
			if x ~= 0 or y ~= 0 or z ~= 0 then
				local length = math.sqrt(x * x + y * y + z * z)
				table.insert(DIRECTIONS, { x / length, y / length, z / length })
			end
		end
	end
end

-- Share of rays that must get at least as far as the result.
local PERCENTILE = 0.5

local CaveReach = {}

local function isWall(id: number): boolean
	return Blocks.isOpaque(id)
end

--[[
	How open the space around (x, y, z) is (blocks, at most `maxDistance`). Unloaded blocks
	(`getBlock` returns nil) let rays through.
]]
function CaveReach.probe(
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number,
	maxDistance: number
): number
	local distances = table.create(#DIRECTIONS)
	for i, d in DIRECTIONS do
		local hit = VoxelRaycast.cast(x, y, z, d[1], d[2], d[3], maxDistance, getBlock, isWall)
		distances[i] = if hit then hit.distance else maxDistance
	end
	table.sort(distances)
	return distances[math.max(1, math.floor(#distances * (1 - PERCENTILE)) + 1)]
end

export type Tracker = {
	radius: number,
	-- Feed the latest probe (nil while above ground); returns the reveal radius.
	update: (self: Tracker, open: number?, now: number) -> number,
}

--[[
	Reveal radius between `min` and `max` (blocks): the open distance plus `step`, rounded up to
	`step`. A smaller radius is only taken once it was wanted for `shrinkDelay` seconds.
]]
function CaveReach.tracker(min: number, max: number, step: number, shrinkDelay: number): Tracker
	local tracker = { radius = min }
	local smallerSince: number? = nil

	function tracker.update(self: Tracker, open: number?, now: number): number
		local want = min
		if open then
			want = math.clamp(math.ceil((open + step) / step) * step, min, max)
		end
		local since = smallerSince
		if want >= self.radius or (since and now - since >= shrinkDelay) then
			self.radius = want
			smallerSince = nil
		elseif since == nil then
			smallerSince = now
		end
		return self.radius
	end

	return (tracker :: any) :: Tracker
end

--[[ Revealed sections ]]

--[[
	Is section `s` of full detail chunk (cx, cz) meshed with caves visible for a camera at (x, y, z)
	(blocks) revealing caves `reach` blocks around it (to section centres)?
]]
function CaveReach.reveals(cx: number, cz: number, s: number, x: number, y: number, z: number, reach: number): boolean
	local dx = (cx + 0.5) * SIZE - x
	local dz = (cz + 0.5) * SIZE - z
	local dy = (s + 0.5) * SECTION - y
	return dx * dx + dy * dy + dz * dz < reach * reach
end

--[[
	The GreedyMesher.Border hidden mask of revealed section `s` of chunk (cx, cz): the sides beyond
	which caves are hidden, so its tunnels end in stone there. `desired` holds the full detail
	chunks (by Coords.chunkKey; a coarser node next to it has no caves at all).
]]
function CaveReach.capMask(
	desired: { [number]: any },
	cx: number,
	cz: number,
	s: number,
	x: number,
	y: number,
	z: number,
	reach: number
): number
	local mask = 0
	for i, side in SIDES do
		local nx, nz = cx + side[1], cz + side[2]
		if desired[Coords.chunkKey(nx, nz)] == nil or not CaveReach.reveals(nx, nz, s, x, y, z, reach) then
			mask += bit32.lshift(1, i - 1)
		end
	end
	if s > 0 and not CaveReach.reveals(cx, cz, s - 1, x, y, z, reach) then
		mask += GreedyMesher.HIDDEN_BELOW
	end
	if s < SECTIONS - 1 and not CaveReach.reveals(cx, cz, s + 1, x, y, z, reach) then
		mask += GreedyMesher.HIDDEN_ABOVE
	end
	return mask
end

--[[ The underground hold ]]

export type Hold = {
	-- Until when (the `now` clock) the hold lasts.
	untilTime: number,
	-- Feed whether the cave view is active now; returns whether the underground split applies.
	update: (self: Hold, active: boolean, now: number) -> boolean,
}

-- True while the cave view is active and for `seconds` after it ended.
function CaveReach.hold(seconds: number): Hold
	local hold = { untilTime = -math.huge }
	function hold.update(self: Hold, active: boolean, now: number): boolean
		if active then
			self.untilTime = now + seconds
			return true
		end
		return now < self.untilTime
	end
	return (hold :: any) :: Hold
end

return CaveReach

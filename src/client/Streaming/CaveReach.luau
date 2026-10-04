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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

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
		if want >= self.radius then
			self.radius = want
			smallerSince = nil
		elseif smallerSince == nil then
			smallerSince = now
		elseif now - smallerSince >= shrinkDelay then
			self.radius = want
			smallerSince = nil
		end
		return self.radius
	end

	return (tracker :: any) :: Tracker
end

return CaveReach

--!strict
--[[
	The cave view: which sections of full detail chunks an underground camera reveals (meshes with
	their cave walls; elsewhere cave air counts as rock, see Blocks.cullLutHiddenCaves). Pure,
	tested in tests/spec/CaveView and tests/spec/Caves.

	Revealed sections (`view`) are the ones Shared/World/SectionGraph's search reaches from the
	camera through connected cave air (Minecraft's advanced cave culling): caves behind rock cost
	nothing and a tunnel is seen along its length instead of being cut off by a sphere. A section
	that drops out of the search stays revealed a little while (`hold` seconds) so it does not
	remesh back and forth, and sections of full detail chunks not generated yet that the search
	would enter count as revealed (the chunk is generated with them revealed). `capMask` closes
	the tunnels of a revealed section in stone where they run into hidden space: a section the
	search misses shows a stone cap, never the void.

	How far the search goes (`searchReach`): tunnels out to the cave view's tunnel reach
	(Caves.RevealReach at the default cave view, PlayerSettings.revealReach), big caverns as far as
	the open space around the camera says. A big cavern (the Underlands under the highest mountains
	are hundreds of blocks across) would show rock a few dozen blocks away, so `probe` casts rays
	through the loaded blocks, sideways and upwards (the camera is usually just above a floor, which
	says nothing about the size of the space), and takes the median of how far they get: open
	space all around reaches far, a single long tunnel or shaft does not. A `Tracker` turns that
	into a radius in whole sections, growing at once but shrinking only after the open space stayed
	smaller for a while; the search then reaches that radius plus a section (what the reveal
	sphere used to reveal), within a section budget.

	Also a `hold` that keeps the cave view's extended full detail range
	(Lod.UndergroundSplitDistanceL1) for a few seconds after the camera comes up (not after a
	teleport: `reset`). Only a camera shut in underground (`enclosed`) starts it: at the open
	bottom of a pit, a ravine or a shaft dug from the surface what is seen is the sky and the
	surface, and stepping into any of the many cave entrances would otherwise load 70-90% more
	full detail chunks for nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local SectionGraph = require(Shared.World.SectionGraph)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

local SIZE = Config.ChunkSize
local SECTION = Config.SectionHeight

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

--[[
	Is a camera at (x, y, z) below its column's generated surface (`surface`, the first cell above
	the uncarved ground) shut in: in a cave cell (cave air or a cave twin: a cavern under a
	ravine's cut too), or under an opaque block below the surface? Not at the open bottom of a pit,
	a ravine or a shaft dug from the surface. Cells not loaded (`getBlock` returns nil) count as
	shut in: generated ground is.
]]
function CaveReach.enclosed(
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number,
	surface: number
): boolean
	local bx, by, bz = math.floor(x), math.floor(y), math.floor(z)
	local here = getBlock(bx, by, bz)
	if here == nil or here == Blocks.CAVE_AIR or buffer.readu8(Blocks.caveTwinLut, here) == 1 then
		return true
	end
	for cy = by + 1, surface - 1 do
		local id = getBlock(bx, cy, bz)
		if id == nil or Blocks.isOpaque(id) then
			return true
		end
	end
	return false
end

export type Tracker = {
	radius: number,
	-- Feed the latest probe (nil while above ground); returns the reveal radius.
	update: (self: Tracker, open: number?, now: number) -> number,
	-- Back to the smallest radius at once (a teleport: the old place's space says nothing).
	reset: (self: Tracker) -> (),
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

	function tracker.reset(self: Tracker)
		self.radius = min
		smallerSince = nil
	end

	return (tracker :: any) :: Tracker
end

--[[ The revealed set ]]

--[[
	How far the search may go from a camera in the open space `radius` (a Tracker's) when tunnels
	reach `tunnels` blocks: big caverns (radius grown by the probe) see as far as the old reveal
	sphere did (radius + a section), tunnels further.
]]
function CaveReach.searchReach(tunnels: number, radius: number): number
	return math.max(tunnels, radius + SECTION)
end

export type View = {
	-- Revealed section keys (SectionGraph.key), and how many.
	revealed: { [number]: boolean },
	count: number,
	-- The last search: the camera's section key (nil above ground), reach, sections reached,
	-- whether the budget cut it, how long it took (ms); searches so far.
	cameraKey: number?,
	reach: number,
	reached: number,
	truncated: boolean,
	searchMs: number,
	searches: number,
	--[[
		Feed the camera (blocks; nil above ground) at time `now` (seconds): searches again when the
		camera changed section, the reach changed or `dirty` (graphs or the full detail chunks
		around changed), and expires what was unreachable for `hold` seconds. Returns the keys
		revealed and hidden by this update.
	]]
	update: (
		self: View,
		lookup: SectionGraph.Lookup,
		x: number?,
		y: number?,
		z: number?,
		reach: number,
		now: number,
		dirty: boolean
	) -> ({ number }, { number }),
	-- Is section `s` of chunk (cx, cz) revealed?
	reveals: (self: View, cx: number, cz: number, s: number) -> boolean,
	-- The GreedyMesher.Border hidden mask of section `s` of chunk (cx, cz) (SectionGraph.capMask).
	capMask: (self: View, cx: number, cz: number, s: number, fullDetail: (cx: number, cz: number) -> boolean) -> number,
}

--[[
	The cave view's revealed sections (SectionGraph's search, see the header of World/SectionGraph):
	what the latest search reached, plus the sections of full detail chunks not generated yet it
	would have entered (so a chunk is generated revealed where the cave runs into it, and its
	neighbours keep their tunnels open meanwhile). A section that drops out of the search stays
	revealed `hold` seconds (so turning round a corner, or stepping out of a cave and back, does
	not remesh it twice); `budget` sections at most (SectionGraph's budget: the giant Underlands).
]]
function CaveReach.view(hold: number, budget: number): View
	local revealed: { [number]: boolean } = {}
	-- Reached or pending in the latest search, and when each other revealed key was last so.
	local current: { [number]: boolean } = {}
	local lastSeen: { [number]: number } = {}
	-- No revealed key expires before this.
	local nextExpiry = math.huge
	local view = {
		revealed = revealed,
		count = 0,
		cameraKey = nil :: number?,
		reach = 0,
		reached = 0,
		truncated = false,
		searchMs = 0,
		searches = 0,
	}

	function view.update(
		self: View,
		lookup: SectionGraph.Lookup,
		x: number?,
		y: number?,
		z: number?,
		reach: number,
		now: number,
		dirty: boolean
	): ({ number }, { number })
		local added, removed = {}, {}
		local searched = false
		if x == nil or y == nil or z == nil then
			if self.cameraKey ~= nil or next(current) ~= nil then
				-- Above ground: everything revealed goes once unseen for `hold` seconds.
				for key in current do
					lastSeen[key] = now
				end
				current = {}
				self.cameraKey = nil
				self.reached, self.truncated = 0, false
				searched = true
			end
		else
			local bx, by, bz = math.floor(x), math.floor(y), math.floor(z)
			local key = SectionGraph.key(bx // SIZE, bz // SIZE, by // SECTION)
			if dirty or key ~= self.cameraKey or reach ~= self.reach then
				local t0 = os.clock()
				local result = SectionGraph.search(lookup, x, y, z, { reach = reach, budget = budget })
				self.searchMs = (os.clock() - t0) * 1000
				self.searches += 1
				self.cameraKey, self.reach = key, reach
				self.reached, self.truncated = result.count, result.truncated
				-- What the last search reached was reachable until now.
				for k in current do
					lastSeen[k] = now
				end
				local nextCurrent: { [number]: boolean } = {}
				for k in result.reached do
					nextCurrent[k] = true
				end
				for k in result.pending do
					nextCurrent[k] = true
				end
				for k in nextCurrent do
					if not revealed[k] then
						revealed[k] = true
						self.count += 1
						table.insert(added, k)
					end
				end
				current = nextCurrent
				searched = true
			end
		end
		if searched or now >= nextExpiry then
			nextExpiry = math.huge
			for k in revealed do
				if not current[k] then
					local seen = lastSeen[k] or now
					if now - seen >= hold then
						table.insert(removed, k)
					elseif seen + hold < nextExpiry then
						nextExpiry = seen + hold
					end
				end
			end
			for _, k in removed do
				revealed[k] = nil
				lastSeen[k] = nil
			end
			self.count -= #removed
		end
		return added, removed
	end

	function view.reveals(_: View, cx: number, cz: number, s: number): boolean
		return revealed[SectionGraph.key(cx, cz, s)] == true
	end

	function view.capMask(
		_: View,
		cx: number,
		cz: number,
		s: number,
		fullDetail: (cx: number, cz: number) -> boolean
	): number
		return SectionGraph.capMask(revealed, cx, cz, s, fullDetail)
	end

	return (view :: any) :: View
end

--[[ The underground hold ]]

export type Hold = {
	-- Until when (the `now` clock) the hold lasts.
	untilTime: number,
	-- Feed whether the cave view is active now with the camera shut in (`enclosed`); returns
	-- whether the underground split applies.
	update: (self: Hold, active: boolean, now: number) -> boolean,
	-- Ends the hold at once (a teleport: the place it was for is gone).
	reset: (self: Hold) -> (),
}

-- True while the cave view is active (shut in) and for `seconds` after it ended.
function CaveReach.hold(seconds: number): Hold
	local hold = { untilTime = -math.huge }
	function hold.update(self: Hold, active: boolean, now: number): boolean
		if active then
			self.untilTime = now + seconds
			return true
		end
		return now < self.untilTime
	end
	function hold.reset(self: Hold)
		self.untilTime = -math.huge
	end
	return (hold :: any) :: Hold
end

return CaveReach

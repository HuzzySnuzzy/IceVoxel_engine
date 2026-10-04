--!strict
--[[
	Bookkeeping for MeshOverlay: which far nodes are drawn as parts, which regions are stable enough
	to merge into meshes, and when a mesh must go. Pure Luau (no instances), so it is unit tested.

	Nodes of level >= minLevel are grouped into regions: aligned squares of `regionNodes` x
	`regionNodes` nodes of one level (at most `maxRegionBlocks` wide). A region's members are its
	shown nodes; they are always built as parts first (the streamer and ChunkRenderer work as without
	meshes). Once a region's members have not changed for `stableSeconds`, it is a candidate: a mesh
	of exactly those members is built in the background and, if they are still the same when it is
	done, shown instead of their parts. A meshed region that gained members (still drawn as parts,
	correctly) is rebuilt only after `rebuildSeconds`, so regions on the edge of the view are not
	rebuilt for every node that appears. Candidates are ranked by the parts a build saves times how
	long they have waited, so no region waits forever.

	A mesh only ever shows nodes that are members: when a node it contains is removed or changes, the
	region is demoted (mesh destroyed, parts shown again) in the same frame. Nodes added to a meshed
	region simply stay parts until the region is rebuilt.
]]

export type Node = any

export type Region = {
	key: string,
	level: number,
	members: { [Node]: boolean },
	count: number,
	-- Bumped on every membership or member content change.
	version: number,
	changedAt: number,
	-- Members shown by the current mesh (nil while drawn as parts), and the version it was built at.
	meshed: { [Node]: number }?,
	meshVersion: number?,
	building: Job?,
	failures: number,
	retryAt: number,
}

export type Job = {
	region: Region,
	version: number,
	members: { Node },
	revisions: { number },
	-- For the caller (e.g. the members' mesh data at the time the build started).
	payload: any,
}

export type Options = {
	minLevel: number,
	regionNodes: number,
	maxRegionBlocks: number,
	stableSeconds: number,
	rebuildSeconds: number,
	nodeSize: (level: number) -> number,
}

export type Stats = {
	regions: number,
	meshed: number,
	building: number,
	nodes: number,
	meshedNodes: number,
}

export type MeshRegions = {
	options: Options,
	regions: { [string]: Region },
	-- Region of each member, and each node's content revision.
	regionOf: { [Node]: Region },
	revision: { [Node]: number },

	keyOf: (self: MeshRegions, level: number, nx: number, nz: number) -> string?,
	add: (self: MeshRegions, node: Node, now: number) -> (),
	remove: (self: MeshRegions, node: Node, now: number) -> Region?,
	changed: (self: MeshRegions, node: Node, now: number) -> Region?,
	candidate: (self: MeshRegions, now: number, ready: (node: Node) -> boolean) -> Region?,
	begin: (self: MeshRegions, region: Region) -> Job,
	finish: (self: MeshRegions, job: Job, ok: boolean, now: number) -> boolean,
	demoted: (self: MeshRegions, region: Region, now: number) -> (),
	meshedRegions: (self: MeshRegions) -> { Region },
	stats: (self: MeshRegions) -> Stats,
}

local MeshRegions = {}
MeshRegions.__index = MeshRegions

function MeshRegions.new(options: Options): MeshRegions
	local self = {
		options = options,
		regions = {},
		regionOf = {},
		revision = {},
	}
	return (setmetatable(self, MeshRegions) :: any) :: MeshRegions
end

-- Key of the region holding node (level, nx, nz), or nil when that level is not merged.
function MeshRegions.keyOf(self: MeshRegions, level: number, nx: number, nz: number): string?
	local options = self.options
	local size = options.nodeSize(level)
	if level < options.minLevel or size > options.maxRegionBlocks then
		return nil
	end
	local perSide = math.max(1, math.min(options.regionNodes, options.maxRegionBlocks // size))
	return `{level}:{nx // perSide},{nz // perSide}`
end

local function touch(region: Region, now: number)
	region.version += 1
	region.changedAt = now
end

-- A node became visible (as parts).
function MeshRegions.add(self: MeshRegions, node: Node, now: number)
	if self.regionOf[node] then
		return
	end
	local key = self:keyOf(node.level, node.nx, node.nz)
	if key == nil then
		return
	end
	local region = self.regions[key]
	if region == nil then
		region = {
			key = key,
			level = node.level,
			members = {},
			count = 0,
			version = 0,
			changedAt = now,
			meshed = nil,
			meshVersion = nil,
			building = nil,
			failures = 0,
			retryAt = 0,
		}
		self.regions[key] = region
	end
	region.members[node] = true
	region.count += 1
	self.regionOf[node] = region
	self.revision[node] = self.revision[node] or 0
	touch(region, now)
end

--[[
	A node is no longer shown. Returns its region when the region's mesh contains it: the caller
	must demote that region now (and then call `demoted`).
]]
function MeshRegions.remove(self: MeshRegions, node: Node, now: number): Region?
	local region = self.regionOf[node]
	self.revision[node] = nil
	if region == nil then
		return nil
	end
	self.regionOf[node] = nil
	region.members[node] = nil
	region.count -= 1
	touch(region, now)
	local demote = region.meshed ~= nil and (region.meshed :: { [Node]: number })[node] ~= nil
	if region.count == 0 and region.meshed == nil and region.building == nil then
		self.regions[region.key] = nil
	end
	return if demote then region else nil
end

-- A shown node's content changed (rebuilt parts). Returns its region if its mesh shows the old content.
function MeshRegions.changed(self: MeshRegions, node: Node, now: number): Region?
	local region = self.regionOf[node]
	if region == nil then
		return nil
	end
	self.revision[node] += 1
	touch(region, now)
	if region.meshed ~= nil and (region.meshed :: { [Node]: number })[node] ~= nil then
		return region
	end
	return nil
end

--[[
	The region most worth meshing now: stable (see the header), not failed recently, not being
	built, with every member `ready` (its quads are known), and not already meshed as it is. Ranked
	by the nodes the build would take out of the workspace times the seconds it has been waiting.
]]
function MeshRegions.candidate(self: MeshRegions, now: number, ready: (node: Node) -> boolean): Region?
	local best: Region? = nil
	local bestScore = 0
	local options = self.options
	for _, region in self.regions do
		local meshed = region.meshed
		local waited = now - region.changedAt
		if
			region.building == nil
			and region.count > 0
			and now >= region.retryAt
			and region.meshVersion ~= region.version
			and waited >= (if meshed then options.rebuildSeconds else options.stableSeconds)
		then
			local saves = region.count
			if meshed then
				for node in region.members do
					if (meshed :: { [Node]: number })[node] then
						saves -= 1
					end
				end
			end
			local score = math.max(saves, 0.5) * (waited + 1)
			if score > bestScore then
				local allReady = true
				for node in region.members do
					if not ready(node) then
						allReady = false
						break
					end
				end
				if allReady then
					best, bestScore = region, score
				end
			end
		end
	end
	return best
end

-- Snapshot of the region's members for a mesh build.
function MeshRegions.begin(self: MeshRegions, region: Region): Job
	assert(region.building == nil, "region already building")
	local members: { Node } = {}
	for node in region.members do
		table.insert(members, node)
	end
	-- Deterministic order (the mesh is split by triangle count in this order).
	table.sort(members, function(a, b)
		if a.nz ~= b.nz then
			return a.nz < b.nz
		end
		return a.nx < b.nx
	end)
	local revisions = table.create(#members)
	for i, node in members do
		revisions[i] = self.revision[node]
	end
	local job: Job =
		{ region = region, version = region.version, members = members, revisions = revisions, payload = nil }
	region.building = job
	return job
end

--[[
	A build ended. Returns true when its mesh may be shown: every node in it is still a member with
	the same content (members added meanwhile stay parts). On failure the region waits before it is
	tried again (2, 4, 8 ... up to 64 seconds).
]]
function MeshRegions.finish(self: MeshRegions, job: Job, ok: boolean, now: number): boolean
	local region = job.region
	if region.building == job then
		region.building = nil
	end
	if region.count == 0 and region.meshed == nil then
		-- Every member left while it was being built.
		self.regions[region.key] = nil
		return false
	end
	if not ok then
		region.failures += 1
		region.retryAt = now + math.min(2 ^ region.failures, 64)
		return false
	end
	for i, node in job.members do
		if not region.members[node] or self.revision[node] ~= job.revisions[i] then
			return false
		end
	end
	local meshed: { [Node]: number } = {}
	for i, node in job.members do
		meshed[node] = job.revisions[i]
	end
	region.meshed = meshed
	region.meshVersion = job.version
	region.failures = 0
	return true
end

-- The caller destroyed the region's mesh and shows its members as parts again.
function MeshRegions.demoted(self: MeshRegions, region: Region, now: number)
	region.meshed = nil
	region.meshVersion = nil
	region.changedAt = now
	if region.count == 0 and region.building == nil then
		self.regions[region.key] = nil
	end
end

function MeshRegions.meshedRegions(self: MeshRegions): { Region }
	local list = {}
	for _, region in self.regions do
		if region.meshed then
			table.insert(list, region)
		end
	end
	return list
end

function MeshRegions.stats(self: MeshRegions): Stats
	local stats: Stats = { regions = 0, meshed = 0, building = 0, nodes = 0, meshedNodes = 0 }
	for _, region in self.regions do
		stats.regions += 1
		stats.nodes += region.count
		if region.meshed then
			stats.meshed += 1
			for _ in region.meshed :: { [Node]: number } do
				stats.meshedNodes += 1
			end
		end
		if region.building then
			stats.building += 1
		end
	end
	return stats
end

return MeshRegions

--!strict
--[[
	The order nodes are generated and built in (lower score is sooner). Pure, tested in
	tests/spec/Streaming.

	The "hybrid" score (research: perf/culling sim.luau, which filled the view 1.6-5x sooner after a
	teleport than distance stretched by facing, and turning round no slower):
	  * the ring under the player (closer than NEAR blocks) goes by distance in every direction (the
	    ground to stand on, and what collides);
	  * nodes in the view wedge (the camera's horizontal field of view plus MARGIN on each side) and
	    not hidden behind terrain go by distance;
	  * behind the camera, nodes closer than BEHIND blocks go by twice their distance (turning round
	    finds them loaded);
	  * the rest go after everything in view (OUT_OF_VIEW), and hidden ones after that (OCCLUDED).

	Replacement groups (`share`): all wanted nodes under one shown node that is being replaced get
	the best score among them, because the old node only goes when all of them are ready; a visible
	sibling never waits for a hidden one.

	Queues are kept sorted with the most urgent node last (`insert`: binary search), so taking the
	next node is O(1).
]]

local LoadPriority = {}

LoadPriority.NEAR = 32
LoadPriority.BEHIND = 128
LoadPriority.MARGIN = math.rad(15)
LoadPriority.OUT_OF_VIEW = 1e5
LoadPriority.OCCLUDED = 2e5

local NEAR = LoadPriority.NEAR
local BEHIND = LoadPriority.BEHIND
local OUT_OF_VIEW = LoadPriority.OUT_OF_VIEW
local OCCLUDED = LoadPriority.OCCLUDED
local TAU = 2 * math.pi

-- Score of a node `distance` blocks away (LodTree.distance), in the view wedge or not, hidden
-- behind terrain or not.
function LoadPriority.score(distance: number, inView: boolean, occluded: boolean): number
	if distance < NEAR then
		return distance
	end
	if inView and not occluded then
		return distance
	end
	if not inView and distance < BEHIND then
		return 2 * distance
	end
	return distance + (if inView then 0 else OUT_OF_VIEW) + (if occluded then OCCLUDED else 0)
end

--[[ The view wedge ]]

export type View = {
	-- Viewer (blocks) and the look direction's angle in the XZ plane (radians, atan2(z, x)).
	x: number,
	z: number,
	angle: number,
	-- Half the wedge's opening (radians).
	half: number,
}

-- Horizontal field of view (radians) of a camera with vertical field of view `fov` (degrees).
function LoadPriority.horizontalFov(fov: number, aspect: number): number
	return 2 * math.atan(math.tan(math.rad(fov) / 2) * aspect)
end

--[[
	The wedge for a viewer at (x, z) looking along (lookX, lookZ) (any length; a vertical look
	counts as every direction), with a camera of vertical field of view `fov` (degrees) and
	aspect ratio `aspect`.
]]
function LoadPriority.view(x: number, z: number, lookX: number, lookZ: number, fov: number, aspect: number): View
	local half = LoadPriority.horizontalFov(fov, aspect) / 2 + LoadPriority.MARGIN
	if lookX * lookX + lookZ * lookZ < 1e-6 then
		half = math.pi
	end
	return { x = x, z = z, angle = math.atan2(lookZ, lookX), half = math.min(half, math.pi) }
end

-- Angle `a` brought into [-pi, pi).
local function wrap(a: number): number
	return (a + math.pi) % TAU - math.pi
end

--[[
	Does any part of the square [x0, x0 + size] x [z0, z0 + size] (blocks) lie in the wedge? A
	viewer inside it, or within `size / 64 + 1` blocks of it, always sees it.
]]
function LoadPriority.inView(view: View, x0: number, z0: number, size: number): boolean
	if view.half >= math.pi then
		return true
	end
	local x, z = view.x, view.z
	local margin = size / 64 + 1
	if x > x0 - margin and x < x0 + size + margin and z > z0 - margin and z < z0 + size + margin then
		return true
	end
	-- The square, seen from outside, spans less than half a turn around the direction to its
	-- centre: the wedge meets it when their angular intervals overlap.
	local centre = math.atan2(z0 + size / 2 - z, x0 + size / 2 - x)
	local lo, hi = math.huge, -math.huge
	for k = 0, 3 do
		local px = if k % 2 == 0 then x0 else x0 + size
		local pz = if k < 2 then z0 else z0 + size
		local d = wrap(math.atan2(pz - z, px - x) - centre)
		if d < lo then
			lo = d
		end
		if d > hi then
			hi = d
		end
	end
	local look = wrap(view.angle - centre)
	return look + view.half >= lo and look - view.half <= hi
end

--[[ Replacement groups ]]

--[[
	Gives every member of a group the lowest priority among the group's members. `groups` maps a
	group key to its members (tables with a `priority`).
]]
function LoadPriority.share(groups: { [any]: { { priority: number } } })
	for _, members in groups do
		if #members > 1 then
			local best = math.huge
			for _, member in members do
				if member.priority < best then
					best = member.priority
				end
			end
			for _, member in members do
				member.priority = best
			end
		end
	end
end

--[[ Sorted queues (most urgent last) ]]

-- Inserts `item` into `queue` (sorted by `priority`, highest first) after equal priorities, so
-- among equals the newest comes out first.
function LoadPriority.insert<T>(queue: { T }, item: T, priority: (T) -> number)
	local p = priority(item)
	local lo, hi = 1, #queue + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if priority(queue[mid]) >= p then
			lo = mid + 1
		else
			hi = mid
		end
	end
	table.insert(queue, lo, item)
end

-- Sorts a queue so the most urgent (lowest priority) comes last.
function LoadPriority.sort<T>(queue: { T }, priority: (T) -> number)
	table.sort(queue, function(a: T, b: T): boolean
		return priority(a) > priority(b)
	end)
end

return LoadPriority

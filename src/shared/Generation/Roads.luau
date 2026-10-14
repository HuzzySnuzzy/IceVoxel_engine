--!strict
--!native
--[[
	The roads between the zombie apocalypse's cities (Generation/Cities): pure geometry, from two
	gates, a link id, the raw terrain and Config.Cities.Roads alone, so every machine, worker and
	chunk draws the same road.

	  Polyline  N = ceil(length / SPAN) + 1 control points on the straight gate-to-gate line, the
	            inner ones pushed sideways by (hash - 0.5) x 2 x Wobble (Hash of the link id and the
	            point's number); two rounds of Chaikin's corner cutting (each edge's quarter and
	            three-quarter points, the two ends kept), then resampled every Step blocks along the
	            curve into vertices (the last one at the far gate, up to 1.25 Step after the one
	            before it). Chaikin's curve stays inside its
	            control points' hull, and they lie within Wobble of the straight line, so every road
	            column and its blend lie within CORRIDOR (Wobble + Width / 2 + Shoulder + Blend) of
	            that line: the corridor, which Cities' `blocked` and tile classes use without ever
	            building a plan.
	  Grading   each vertex's raw height (water: a selector of the sea, or below the sea level,
	            raised to SeaLevel + 1, a causeway); a moving average over AVERAGE (9) vertices,
	            twice; the ends pinned to each city's plateau, blended over PIN (64) blocks; then a
	            slope clamp: each vertex into the band both plateaus can reach at MaxGrade, then a
	            forward pass, so neighbouring vertices differ by at most their arc distance x
	            MaxGrade and both ends stay exactly on their plateaus.
	  Rejected  a link whose plan crosses more than MaxWater blocks of water in one run, has more
	            than MOUNTAINS (10%) of its vertices in the mountains (|selector| < 0.15), or would
	            cut more than MaxCut or fill more than MaxFill anywhere is dropped, at both ends
	            alike (the plan is the same whichever city asks).
	  Corridor  `touches` (a capsule against a rectangle) and `boxes` (32-aligned boxes covering the
	            capsule inside a rectangle, CORRIDOR wide either side) for the conservative tests.

	`plan` reads the terrain through `sample` ((x, z) -> raw height, selector, river) and calls
	`yield` every PAUSE (64) samples, so a cold plan never runs long in a worker's slice.
]]

local Config = require(script.Parent.Parent.Config)
local Hash = require(script.Parent.Parent.Util.Hash)

local SEA = Config.SeaLevel

-- Tuning --------------------------------------------------------------------------------------------
local SPAN = 128 -- blocks between two control points
local AVERAGE = 4 -- the moving average's half window (9 vertices)
local PIN = 64 -- the ends are blended to the cities' plateaus over this many blocks
local MOUNTAINS = 0.1 -- a link with more of its vertices in the mountains is dropped
local MOUNTAIN_SELECTOR = 0.15
local WATER_SELECTOR = 0.4
local PAUSE = 64 -- terrain samples between two yields
local ALIGN = 32 -- `boxes` are aligned to this

local sqrt = math.sqrt
local floor, ceil = math.floor, math.ceil
local min, max = math.min, math.max
local abs = math.abs

-- (x, z) -> raw full detail height (first air, fractional), selector, river strength.
export type Sampler = (x: number, z: number) -> (number, number, number)

--[[
	A road's plan: `count` vertices (x, z), their graded height `y` (fractional; the road's first air
	above them) and arc length `s` from gate a; the straight line between the gates (ax, az to bx,
	bz: the corridor's axis); `rejected` with the `reason` (no road is built, the corridor still
	counts as `blocked`).
]]
export type Plan = {
	id: number,
	ax: number,
	az: number,
	bx: number,
	bz: number,
	count: number,
	x: { number },
	z: { number },
	y: { number },
	s: { number },
	rejected: boolean,
	reason: string?,
}

local Roads = {}

Roads.SPAN = SPAN
Roads.PIN = PIN
Roads.PAUSE = PAUSE

-- How far a road column or its blend lies at most from its link's straight gate-to-gate line.
function Roads.corridor(): number
	local cfg = Config.Cities.Roads
	return cfg.Wobble + cfg.Width / 2 + cfg.Shoulder + cfg.Blend
end

-- Half width of the road's level band (asphalt and shoulder), and its blend's outer edge.
function Roads.band(): (number, number)
	local cfg = Config.Cities.Roads
	local band = cfg.Width / 2 + cfg.Shoulder
	return band, band + cfg.Blend
end

local function smoothstep01(t: number): number
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end
Roads.smoothstep = smoothstep01

--[[ Polyline ]]

-- The control points of link `id` from gate a to gate b (see the header).
function Roads.controlPoints(ax: number, az: number, bx: number, bz: number, id: number): ({ number }, { number })
	local wobble = Config.Cities.Roads.Wobble
	local dx, dz = bx - ax, bz - az
	local length = sqrt(dx * dx + dz * dz)
	local n = max(1, ceil(length / SPAN))
	local nx, nz = 0, 0
	if length > 0 then
		nx, nz = -dz / length, dx / length
	end
	local xs, zs = table.create(n + 1), table.create(n + 1)
	for i = 0, n do
		local t = i / n
		local px, pz = ax + dx * t, az + dz * t
		if i > 0 and i < n then
			local offset = (Hash.hash3(id, i, 0x0AD5, 0) / 4294967296 - 0.5) * 2 * wobble
			px += nx * offset
			pz += nz * offset
		end
		xs[i + 1], zs[i + 1] = px, pz
	end
	return xs, zs
end

-- One round of Chaikin's corner cutting, the two ends kept.
local function chaikin(xs: { number }, zs: { number }): ({ number }, { number })
	local n = #xs
	if n < 3 then
		return xs, zs
	end
	local ox, oz = table.create(2 * n), table.create(2 * n)
	table.insert(ox, xs[1])
	table.insert(oz, zs[1])
	for i = 1, n - 1 do
		local x0, z0, x1, z1 = xs[i], zs[i], xs[i + 1], zs[i + 1]
		table.insert(ox, 0.75 * x0 + 0.25 * x1)
		table.insert(oz, 0.75 * z0 + 0.25 * z1)
		table.insert(ox, 0.25 * x0 + 0.75 * x1)
		table.insert(oz, 0.25 * z0 + 0.75 * z1)
	end
	table.insert(ox, xs[n])
	table.insert(oz, zs[n])
	return ox, oz
end
Roads.chaikin = chaikin

--[[
	The vertices of link `id` from gate a to gate b: the smoothed curve resampled every Step blocks
	(x, z and arc length s; the last vertex is gate b).
]]
function Roads.vertices(
	ax: number,
	az: number,
	bx: number,
	bz: number,
	id: number
): ({ number }, { number }, { number })
	local step = Config.Cities.Roads.Step
	local xs, zs = Roads.controlPoints(ax, az, bx, bz, id)
	xs, zs = chaikin(xs, zs)
	xs, zs = chaikin(xs, zs)
	local vx, vz, vs = { xs[1] }, { zs[1] }, { 0 }
	local travelled = 0 -- arc length at xs[i]
	local nextAt = step
	for i = 1, #xs - 1 do
		local x0, z0, x1, z1 = xs[i], zs[i], xs[i + 1], zs[i + 1]
		local dx, dz = x1 - x0, z1 - z0
		local length = sqrt(dx * dx + dz * dz)
		while length > 0 and nextAt <= travelled + length do
			local t = (nextAt - travelled) / length
			table.insert(vx, x0 + dx * t)
			table.insert(vz, z0 + dz * t)
			table.insert(vs, nextAt)
			nextAt += step
		end
		travelled += length
	end
	-- The far gate itself (a last, shorter step; one too short to count is replaced).
	if travelled - vs[#vs] < step / 4 and #vs > 1 then
		vx[#vx], vz[#vz], vs[#vs] = xs[#xs], zs[#zs], travelled
	else
		table.insert(vx, xs[#xs])
		table.insert(vz, zs[#zs])
		table.insert(vs, travelled)
	end
	return vx, vz, vs
end

--[[ Grading ]]

--[[
	The plan of link `id` between gate a (on a city whose plateau is `ya`) and gate b (plateau
	`yb`), the raw terrain read through `sample` (see the header).
]]
function Roads.plan(
	id: number,
	ax: number,
	az: number,
	ya: number,
	bx: number,
	bz: number,
	yb: number,
	sample: Sampler,
	yield: (() -> ())?
): Plan
	local cfg = Config.Cities.Roads
	local vx, vz, vs = Roads.vertices(ax, az, bx, bz, id)
	local count = #vx
	local raw = table.create(count, 0)
	local g = table.create(count, 0)
	local water = 0
	local longest = 0
	local mountains = 0
	local work = 0
	for i = 1, count do
		local y, selector, _ = sample(vx[i], vz[i])
		local a = abs(selector)
		raw[i] = y
		if a >= WATER_SELECTOR or y < SEA then
			water += 1
			longest = max(longest, water)
			g[i] = max(y, SEA + 1)
		else
			water = 0
			g[i] = y
		end
		if a < MOUNTAIN_SELECTOR then
			mountains += 1
		end
		work += 1
		if yield and work >= PAUSE then
			work = 0
			yield()
		end
	end
	-- The moving average, twice.
	local tmp = table.create(count, 0)
	for _ = 1, 2 do
		for i = 1, count do
			local sum, n = 0, 0
			for j = max(1, i - AVERAGE), min(count, i + AVERAGE) do
				sum += g[j]
				n += 1
			end
			tmp[i] = sum / n
		end
		g, tmp = tmp, g
	end
	-- The ends pinned to the plateaus.
	local length = vs[count]
	for i = 1, count do
		local s = vs[i]
		g[i] += (ya - g[i]) * (1 - smoothstep01(s / PIN))
		g[i] += (yb - g[i]) * (1 - smoothstep01((length - s) / PIN))
	end
	-- The slope clamp: first into the band both pinned ends can reach at MaxGrade, then forward.
	-- Each vertex stays in that band (it narrows by at most a step's grade from one vertex to the
	-- next), so the last one ends at gate b's plateau, and every step keeps the grade.
	local grade = cfg.MaxGrade
	for i = 1, count do
		local s = vs[i]
		local lo = max(ya - s * grade, yb - (length - s) * grade)
		local hi = min(ya + s * grade, yb + (length - s) * grade)
		if lo > hi then
			lo, hi = (lo + hi) / 2, (lo + hi) / 2
		end
		g[i] = math.clamp(g[i], lo, hi)
	end
	for i = 2, count do
		local d = (vs[i] - vs[i - 1]) * grade
		g[i] = math.clamp(g[i], g[i - 1] - d, g[i - 1] + d)
	end
	-- Rejected?
	local reason: string? = nil
	if longest * cfg.Step > cfg.MaxWater then
		reason = "water"
	elseif mountains > count * MOUNTAINS then
		reason = "mountains"
	else
		for i = 1, count do
			local d = g[i] - raw[i]
			if d > cfg.MaxFill then
				reason = "fill"
				break
			elseif -d > cfg.MaxCut then
				reason = "cut"
				break
			end
		end
	end
	return {
		id = id,
		ax = ax,
		az = az,
		bx = bx,
		bz = bz,
		count = count,
		x = vx,
		z = vz,
		y = g,
		s = vs,
		rejected = reason ~= nil,
		reason = reason,
	}
end

--[[ Geometry ]]

-- Squared distance from (px, pz) to the segment (ax, az)-(bx, bz), and the parameter t (0..1) of
-- the nearest point on it.
function Roads.segmentDistance2(
	px: number,
	pz: number,
	ax: number,
	az: number,
	bx: number,
	bz: number
): (number, number)
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = 0
	if l2 > 0 then
		t = ((px - ax) * dx + (pz - az) * dz) / l2
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
	end
	local qx, qz = ax + dx * t - px, az + dz * t - pz
	return qx * qx + qz * qz, t
end
local segmentDistance2 = Roads.segmentDistance2

-- Squared distance from (px, pz) to the rectangle x0..x1, z0..z1 (0 inside).
local function rectDistance2(px: number, pz: number, x0: number, z0: number, x1: number, z1: number): number
	local dx = if px < x0 then x0 - px elseif px > x1 then px - x1 else 0
	local dz = if pz < z0 then z0 - pz elseif pz > z1 then pz - z1 else 0
	return dx * dx + dz * dz
end

-- Do segments a-b and c-d cross?
local function crosses(
	ax: number,
	az: number,
	bx: number,
	bz: number,
	cx: number,
	cz: number,
	dx: number,
	dz: number
): boolean
	local function orient(px: number, pz: number, qx: number, qz: number, rx: number, rz: number): number
		return (qx - px) * (rz - pz) - (qz - pz) * (rx - px)
	end
	local o1 = orient(ax, az, bx, bz, cx, cz)
	local o2 = orient(ax, az, bx, bz, dx, dz)
	local o3 = orient(cx, cz, dx, dz, ax, az)
	local o4 = orient(cx, cz, dx, dz, bx, bz)
	return ((o1 > 0) ~= (o2 > 0)) and ((o3 > 0) ~= (o4 > 0))
end

--[[
	Does the capsule of radius r around segment a-b touch the rectangle x0..x1, z0..z1 (inclusive
	block coordinates: the cells' extent is x0..x1 + 1)? The nearest pair of a segment and a
	rectangle involves an end of the segment or a corner of the rectangle, unless they cross.
]]
function Roads.touches(
	ax: number,
	az: number,
	bx: number,
	bz: number,
	r: number,
	x0: number,
	z0: number,
	x1: number,
	z1: number
): boolean
	x1 += 1
	z1 += 1
	local r2 = r * r
	if rectDistance2(ax, az, x0, z0, x1, z1) <= r2 or rectDistance2(bx, bz, x0, z0, x1, z1) <= r2 then
		return true
	end
	if
		segmentDistance2(x0, z0, ax, az, bx, bz) <= r2
		or segmentDistance2(x1, z0, ax, az, bx, bz) <= r2
		or segmentDistance2(x0, z1, ax, az, bx, bz) <= r2
		or segmentDistance2(x1, z1, ax, az, bx, bz) <= r2
	then
		return true
	end
	return crosses(ax, az, bx, bz, x0, z0, x1, z0)
		or crosses(ax, az, bx, bz, x0, z0, x0, z1)
		or crosses(ax, az, bx, bz, x1, z0, x1, z1)
		or crosses(ax, az, bx, bz, x0, z1, x1, z1)
end

--[[
	Appends x0, z0, x1, z1 boxes (inclusive, ALIGN-aligned, clipped to the query rectangle) whose
	union covers every block within r of segment a-b inside the rectangle: the segment cut into
	pieces at most ALIGN long, each piece's bounds grown by r.
]]
function Roads.boxes(
	ax: number,
	az: number,
	bx: number,
	bz: number,
	r: number,
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	out: { number }
)
	local dx, dz = bx - ax, bz - az
	local length = sqrt(dx * dx + dz * dz)
	local pieces = max(1, ceil(length / ALIGN))
	for i = 0, pieces - 1 do
		local t0, t1 = i / pieces, (i + 1) / pieces
		local px0, pz0 = ax + dx * t0, az + dz * t0
		local px1, pz1 = ax + dx * t1, az + dz * t1
		local bx0 = floor((min(px0, px1) - r) / ALIGN) * ALIGN
		local bz0 = floor((min(pz0, pz1) - r) / ALIGN) * ALIGN
		local bx1 = floor((max(px0, px1) + r) / ALIGN) * ALIGN + ALIGN - 1
		local bz1 = floor((max(pz0, pz1) + r) / ALIGN) * ALIGN + ALIGN - 1
		if bx0 <= x1 and bx1 >= x0 and bz0 <= z1 and bz1 >= z0 then
			table.insert(out, max(bx0, x0))
			table.insert(out, max(bz0, z0))
			table.insert(out, min(bx1, x1))
			table.insert(out, min(bz1, z1))
		end
	end
end

return Roads

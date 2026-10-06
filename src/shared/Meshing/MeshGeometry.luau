--!strict
--[[
	Turns the quads of several chunk nodes (QuadMesher output) into the arrays of one or more meshes,
	each small enough for one EditableMesh / MeshPart. Pure Luau: the client converts the numbers into
	Vector3 / Color3 / Vector2 values and feeds them to the batch APIs (see Rendering/MeshOverlay).

	A mesh holds whole quads, at most `maxTriangles / 2` of them, in the order the nodes and their
	quads are added (per look and band, see below), so the result is deterministic. Each quad becomes
	four vertices of its own (corners wound counter-clockwise, see QuadMesher.corners) and two
	triangles (0, 1, 2) and (0, 2, 3); with unshared vertices the engine's automatic normals are
	exactly the face normals.

	Positions are relative to the centre of the mesh's bounding box (a MeshPart is centred on its
	mesh; place it at `center`). A mesh whose box is flat on some axis (e.g. a sheet of sea water)
	gets one extra tiny quad below it, so no axis of its part is (almost) zero.

	A part may be at most 2048 studs on any axis, and a tall world is taller than that. A region
	whose geometry spans at most MAX_SPAN studs vertically (most do) stays as it is. A taller one is
	cut into horizontal bands of BAND studs from its lowest point: quads go to the meshes of their
	band, and a side face crossing a band boundary is cut there (its corners clamped to each band it
	crosses, plus the overlap). Such a mesh is at most BAND + 2 grow + MIN_EXTENT tall.

	Looks (`Options`, far materials). A MeshPart has one Material and one MaterialVariant, so quads
	of different looks (material + variant + transparency + reflectance: whatever `lookOf` tells
	apart, as small whole numbers) need different meshes. With `lookOf`:
	  * every quad gets its look and vertex colour from `lookOf(appearance, face)` (`face` is the
	    QuadMesher direction: 0 +X, 1 -X, 2 +Y top, 3 -Y bottom, 4 +Z, 5 -Z);
	  * the looks are ranked by the area their quads cover in the builder (a region); a look keeps
	    meshes of its own only when it covers at least `minShare` of the area, and only the
	    `maxLooks` largest do. The other quads are the remainder, drawn in their plain colour
	    (`plainOf(appearance, face)`: what the face averages to on screen; else their own colour,
	    see below): "plain" (default) draws them in the PLAIN look in that colour, "largest" adds
	    them to the largest kept look that `opaque` accepts (plain when none is) and tints them
	    so that look's texture still averages it: the plain colour divided by the look's average
	    (`averageOf(look)`) per channel in linear light, at most 1; the plain colour itself when
	    the average is unknown or the look is PLAIN. (Their own colour is a tint meant for their
	    own look's texture: white for a texture drawn in its own colours.) Without `plainOf` the
	    remainder keeps its own colours;
	  * meshes are grouped by look, then band as above, looks in ascending id order. With one look
	    the meshes are exactly what they are without options (only `colors` is added);
	  * `uvStuds` adds box-mapped UVs: from world studs, per face direction (u to the right and v
	    down, seen from outside; tops and bottoms on X and Z), divided by `uvStuds` and measured
	    from a corner snapped to a multiple of it, so tile edges fall on block edges at every level
	    and across meshes, and the numbers stay small.
	Without options every quad is look PLAIN and meshes carry no colours or UVs (the caller colours
	vertices itself).
]]

local QuadMesher = require(script.Parent.QuadMesher)

local KEY_STRIDE = QuadMesher.KEY_STRIDE
local QUAD_BYTES = QuadMesher.QUAD_BYTES
-- Thinnest a mesh's box may be on any axis (studs); also the size of the quad that ensures it.
local MIN_EXTENT = 0.1
-- Tallest geometry kept in one band, and the height of a band when it has to be cut (studs): both
-- with the in-plane overlap and the anchor quad under the 2048 stud part limit.
local MAX_SPAN = 2000
local BAND = 1536
-- The look of quads drawn without materials (SmoothPlastic in their colour, opaque).
local PLAIN = 0
-- QuadMesher direction of the anchor quad (it faces down).
local DOWN = 3

-- A quad's look and vertex colour (r, g, b in 0..1), by its appearance and face direction.
export type LookOf = (appearance: number, face: number) -> (number, number, number, number)
-- A quad's colour in the plain look (r, g, b in 0..1).
export type PlainOf = (appearance: number, face: number) -> (number, number, number)

export type Options = {
	lookOf: LookOf,
	-- Colours of the plain remainder (default: the quads' own).
	plainOf: PlainOf?,
	-- Share of the builder's quad area a look needs for meshes of its own (default 0), and how
	-- many looks may have them, the largest first (default: every look).
	minShare: number?,
	maxLooks: number?,
	-- What draws the other quads: "plain" (default) or "largest" (see the header).
	remainder: string?,
	-- Which looks the "largest" remainder may join (default: every look).
	opaque: ((look: number) -> boolean)?,
	-- The colour a look's texture averages to at vertex colour white (r, g, b 0..1; nil:
	-- unknown), for the "largest" remainder's tint.
	averageOf: ((look: number) -> { number }?)?,
	-- Studs per UV unit (one texture tile); nil: no UVs.
	uvStuds: number?,
}

export type Mesh = {
	-- x, y, z per vertex, relative to `center` (four vertices per quad).
	positions: { number },
	-- Appearance id of each quad (its four vertices share it).
	appearances: { number },
	quads: number,
	-- Centre and size of the bounding box in studs.
	center: { number },
	size: { number },
	-- The look of every quad (PLAIN without options).
	look: number,
	-- r, g, b per quad (0..1), with options.
	colors: { number }?,
	-- u, v per vertex, with options.uvStuds.
	uvs: { number }?,
}

export type Builder = {
	add: (
		self: Builder,
		quads: buffer,
		count: number,
		originX: number,
		originZ: number,
		scale: number,
		scaleY: number
	) -> (),
	finish: (self: Builder) -> { Mesh },
	-- Quads added so far.
	total: number,
}

type Raw = {
	-- Absolute positions while collecting.
	positions: { number },
	appearances: { number },
	quads: number,
	min: { number },
	max: { number },
	-- With options: r, g, b and the face direction of each quad.
	colors: { number }?,
	dirs: { number }?,
}

local MeshGeometry = {}

MeshGeometry.MIN_EXTENT = MIN_EXTENT
MeshGeometry.BAND = BAND
MeshGeometry.MAX_SPAN = MAX_SPAN
MeshGeometry.PLAIN = PLAIN

local function newRaw(looks: boolean): Raw
	return {
		positions = {},
		appearances = {},
		quads = 0,
		min = { math.huge, math.huge, math.huge },
		max = { -math.huge, -math.huge, -math.huge },
		colors = if looks then {} else nil,
		dirs = if looks then {} else nil,
	}
end

local function push(raw: Raw, x: number, y: number, z: number)
	local positions = raw.positions
	local n = #positions
	positions[n + 1], positions[n + 2], positions[n + 3] = x, y, z
	local min, max = raw.min, raw.max
	if x < min[1] then
		min[1] = x
	end
	if x > max[1] then
		max[1] = x
	end
	if y < min[2] then
		min[2] = y
	end
	if y > max[2] then
		max[2] = y
	end
	if z < min[3] then
		min[3] = z
	end
	if z > max[3] then
		max[3] = z
	end
end

-- sRGB 0..1 -> linear light, and back.
local function toLinear(c: number): number
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end
local function toSrgb(l: number): number
	return if l <= 0.0031308 then l * 12.92 else 1.055 * l ^ (1 / 2.4) - 0.055
end

--[[
	The vertex colour (r, g, b 0..1) that makes a texture averaging `average` (sRGB 0..1) average
	`color` (sRGB 0..1): their ratio per channel in linear light, at most 1 (a vertex colour only
	darkens); `color` itself for an unknown average.
]]
function MeshGeometry.tint(color: { number }, average: { number }?): { number }
	if average == nil then
		return color
	end
	local out = table.create(3)
	for k = 1, 3 do
		local a = toLinear(math.clamp(average[k], 0, 1))
		out[k] = if a > 1e-6 then math.min(1, toSrgb(toLinear(color[k]) / a)) else 1
	end
	return out
end

--[[
	UV of a point (studs from the snapped corner, already divided by the tile size) on a face of
	direction `dir`: u to the right and v down as seen from outside the face (V grows down an
	image); tops and bottoms map X to u and Z to v (bottoms mirrored, as seen from below).
]]
function MeshGeometry.uv(dir: number, x: number, y: number, z: number): (number, number)
	if dir == 0 then
		return -z, -y
	elseif dir == 1 then
		return z, -y
	elseif dir == 2 then
		return x, z
	elseif dir == 3 then
		return x, -z
	elseif dir == 4 then
		return x, -y
	end
	return -x, -y
end
local uvOf = MeshGeometry.uv

--[[
	`blockSize` is Config.BlockSize (for lowered fluid surfaces), `grow` the in-plane overlap of every
	quad (studs), `maxTriangles` the triangle cap per mesh (even, at least 4), `options` the looks
	(see the header; nil: none).
]]
function MeshGeometry.builder(blockSize: number, grow: number, maxTriangles: number, options: Options?): Builder
	assert(maxTriangles >= 4, "maxTriangles too small")
	-- Leave room for the anchor quad.
	local perMesh = maxTriangles // 2 - 1
	local lookOf = if options then options.lookOf else nil
	local looking = lookOf ~= nil
	-- Quads added so far: corners (12 numbers each), appearance, and the vertical extent of the face
	-- itself (without the overlap); with looks also the direction, look, colour and area.
	local corners: { number } = {}
	local appearances: { number } = {}
	local extents: { number } = {}
	local dirs: { number } = {}
	local looks: { number } = {}
	local colors: { number } = {}
	local areas: { number } = {}
	-- lookOf's and plainOf's answers by appearance and direction (appearance * 8 + dir).
	local cachedLook: { [number]: number } = {}
	local cachedColor: { [number]: { number } } = {}
	local cachedPlain: { [number]: { number } } = {}

	local function look(appearance: number, dir: number): (number, { number })
		local key = appearance * 8 + dir
		local id = cachedLook[key]
		if id == nil then
			local got, r, g, b = (lookOf :: LookOf)(appearance, dir)
			assert(got >= 0 and got % 1 == 0, "look ids are whole numbers from 0")
			id = got
			cachedLook[key] = got
			cachedColor[key] = { r, g, b }
		end
		return id :: number, cachedColor[key]
	end

	-- The plain remainder's colour of a quad (nil: its own).
	local function plainColor(appearance: number, dir: number): { number }?
		local plainOf = (options :: Options).plainOf
		if plainOf == nil then
			return nil
		end
		local key = appearance * 8 + dir
		local color = cachedPlain[key]
		if color == nil then
			local r, g, b = plainOf(appearance, dir)
			color = { r, g, b }
			cachedPlain[key] = color
		end
		return color
	end

	local builder = { total = 0 }

	function builder.add(
		self: Builder,
		quads: buffer,
		count: number,
		originX: number,
		originZ: number,
		scale: number,
		scaleY: number
	)
		for i = 0, count - 1 do
			local ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz =
				QuadMesher.corners(quads, i, originX, originZ, scale, scaleY, blockSize, grow)
			local n = #corners
			corners[n + 1], corners[n + 2], corners[n + 3] = ax, ay, az
			corners[n + 4], corners[n + 5], corners[n + 6] = bx, by, bz
			corners[n + 7], corners[n + 8], corners[n + 9] = cx, cy, cz
			corners[n + 10], corners[n + 11], corners[n + 12] = dx, dy, dz
			local appearance = buffer.readu16(quads, i * QUAD_BYTES + 12) % KEY_STRIDE
			table.insert(appearances, appearance)
			local low = math.min(ay, by, cy, dy)
			local high = math.max(ay, by, cy, dy)
			-- Side faces are grown vertically too.
			if high > low then
				low += grow
				high -= grow
			end
			table.insert(extents, low)
			table.insert(extents, high)
			if looking then
				local dir = buffer.readu16(quads, i * QUAD_BYTES)
				local id, color = look(appearance, dir)
				table.insert(dirs, dir)
				table.insert(looks, id)
				local q = #looks
				colors[q * 3 - 2], colors[q * 3 - 1], colors[q * 3] = color[1], color[2], color[3]
				-- (Axis-aligned rectangle: the two side lengths.)
				local u = math.abs(bx - ax) + math.abs(by - ay) + math.abs(bz - az)
				local v = math.abs(dx - ax) + math.abs(dy - ay) + math.abs(dz - az)
				table.insert(areas, u * v)
			end
		end
		self.total += count
	end

	--[[
		The remainder (see the header): ranks the looks by area, keeps the largest ones that cover
		minShare, and moves every other quad to the plain look or to the largest kept opaque one,
		recoloured to its plain colour (tinted for the joined look's texture).
	]]
	local function settleLooks()
		local opts = options :: Options
		local area: { [number]: number } = {}
		local total = 0
		for q, id in looks do
			area[id] = (area[id] or 0) + areas[q]
			total += areas[q]
		end
		local ranked: { number } = {}
		for id in area do
			table.insert(ranked, id)
		end
		table.sort(ranked, function(a, b)
			if area[a] ~= area[b] then
				return area[a] > area[b]
			end
			return a < b
		end)
		local minArea = (opts.minShare or 0) * total
		local maxLooks = opts.maxLooks or math.huge
		local kept: { [number]: boolean } = {}
		local keptCount = 0
		local largest: number? = nil
		local opaque = opts.opaque
		for _, id in ranked do
			if keptCount < maxLooks and area[id] >= minArea then
				kept[id] = true
				keptCount += 1
				if largest == nil and (opaque == nil or opaque(id)) then
					largest = id
				end
			end
		end
		if keptCount == #ranked then
			return
		end
		local joins: number = if opts.remainder == "largest" and largest ~= nil then largest else PLAIN
		-- (The joined look's average, once; PLAIN shows the vertex colour itself.)
		local averageOf = opts.averageOf
		local average = if joins ~= PLAIN and averageOf then averageOf(joins) else nil
		for q, id in looks do
			if not kept[id] then
				looks[q] = joins
				local color = plainColor(appearances[q], dirs[q])
				if color then
					color = MeshGeometry.tint(color, average)
					colors[q * 3 - 2], colors[q * 3 - 1], colors[q * 3] = color[1], color[2], color[3]
				end
			end
		end
	end

	function builder.finish(_self: Builder): { Mesh }
		local count = #appearances
		-- Bands: one, unless the geometry is too tall for a part.
		local spanMin, spanMax, origin = math.huge, -math.huge, math.huge
		for q = 0, count - 1 do
			for k = 2, 11, 3 do
				local y = corners[q * 12 + k]
				spanMin = math.min(spanMin, y)
				spanMax = math.max(spanMax, y)
			end
			origin = math.min(origin, extents[q * 2 + 1])
		end
		local banded = spanMax - spanMin + MIN_EXTENT > MAX_SPAN

		-- The quads of each look (1-based), looks in ascending order.
		local order: { number } = {}
		local byLook: { [number]: { number } } = {}
		if looking then
			settleLooks()
			for q, id in looks do
				local list = byLook[id]
				if list == nil then
					list = {}
					byLook[id] = list
					table.insert(order, id)
				end
				table.insert(list, q)
			end
			table.sort(order)
		elseif count > 0 then
			local all = table.create(count)
			for q = 1, count do
				all[q] = q
			end
			byLook[PLAIN] = all
			order[1] = PLAIN
		end

		local done: { Raw } = {}
		local doneLooks: { number } = {}
		local clamp = math.clamp
		for _, id in order do
			-- Mesh being filled for each band.
			local current: { [number]: Raw } = {}
			local function rawFor(band: number): Raw
				local raw = current[band]
				if raw == nil or raw.quads >= perMesh then
					if raw then
						table.insert(done, raw)
						table.insert(doneLooks, id)
					end
					raw = newRaw(looking)
					current[band] = raw
				end
				return raw
			end

			for _, q1 in byLook[id] do
				local q = q1 - 1
				local o = q * 12
				local first, last = 0, 0
				local low, high = extents[q * 2 + 1], extents[q * 2 + 2]
				if banded then
					first = (low - origin) // BAND
					-- The band holding the top edge; one lower when that edge is exactly on a boundary.
					last = if high > low then math.max(first, math.ceil((high - origin) / BAND) - 1) else first
				end
				for band = first, last do
					local raw = rawFor(band)
					if first == last then
						for k = 1, 12, 3 do
							push(raw, corners[o + k], corners[o + k + 1], corners[o + k + 2])
						end
					else
						-- Pieces overlap by `grow` across the cut, like neighbouring quads.
						local bottom = origin + band * BAND - grow
						local top = origin + (band + 1) * BAND + grow
						for k = 1, 12, 3 do
							push(raw, corners[o + k], clamp(corners[o + k + 1], bottom, top), corners[o + k + 2])
						end
					end
					raw.quads += 1
					raw.appearances[raw.quads] = appearances[q1]
					if looking then
						local rawColors = raw.colors :: { number }
						local rawDirs = raw.dirs :: { number }
						local n = raw.quads * 3
						rawColors[n - 2], rawColors[n - 1], rawColors[n] =
							colors[q1 * 3 - 2], colors[q1 * 3 - 1], colors[q1 * 3]
						rawDirs[raw.quads] = dirs[q1]
					end
				end
			end

			local bands: { number } = {}
			for band in current do
				table.insert(bands, band)
			end
			table.sort(bands)
			for _, band in bands do
				if current[band].quads > 0 then
					table.insert(done, current[band])
					table.insert(doneLooks, id)
				end
			end
		end
		table.clear(corners)
		table.clear(appearances)
		table.clear(extents)
		table.clear(dirs)
		table.clear(looks)
		table.clear(colors)
		table.clear(areas)

		local uvStuds = if options then options.uvStuds else nil
		local meshes: { Mesh } = {}
		for index, raw in done do
			-- Keep every axis of the box at least MIN_EXTENT thick with a tiny quad facing down,
			-- just below the mesh (out of sight under the surfaces it extends).
			local min, max = raw.min, raw.max
			if max[1] - min[1] < MIN_EXTENT or max[2] - min[2] < MIN_EXTENT or max[3] - min[3] < MIN_EXTENT then
				local x, y, z = min[1], min[2] - MIN_EXTENT, min[3]
				local s = MIN_EXTENT
				-- A -Y face: these corners wind counter-clockwise seen from below.
				push(raw, x, y, z)
				push(raw, x + s, y, z)
				push(raw, x + s, y, z + s)
				push(raw, x, y, z + s)
				raw.quads += 1
				raw.appearances[raw.quads] = raw.appearances[1]
				local rawColors = raw.colors
				local rawDirs = raw.dirs
				if rawColors and rawDirs then
					local n = raw.quads * 3
					rawColors[n - 2], rawColors[n - 1], rawColors[n] = rawColors[1], rawColors[2], rawColors[3]
					rawDirs[raw.quads] = DOWN
				end
			end
			local positions = raw.positions
			local uvs: { number }? = nil
			if uvStuds then
				-- From the box's corner snapped to a whole tile.
				local list = table.create(#positions // 3 * 2)
				local ox = math.floor(min[1] / uvStuds) * uvStuds
				local oy = math.floor(min[2] / uvStuds) * uvStuds
				local oz = math.floor(min[3] / uvStuds) * uvStuds
				local rawDirs = raw.dirs :: { number }
				for v = 0, #positions // 3 - 1 do
					local j = v * 3
					local u, w = uvOf(
						rawDirs[v // 4 + 1],
						(positions[j + 1] - ox) / uvStuds,
						(positions[j + 2] - oy) / uvStuds,
						(positions[j + 3] - oz) / uvStuds
					)
					list[v * 2 + 1], list[v * 2 + 2] = u, w
				end
				uvs = list
			end
			local cx, cy, cz = (min[1] + max[1]) / 2, (min[2] + max[2]) / 2, (min[3] + max[3]) / 2
			for j = 1, #positions, 3 do
				positions[j] -= cx
				positions[j + 1] -= cy
				positions[j + 2] -= cz
			end
			table.insert(meshes, {
				positions = positions,
				appearances = raw.appearances,
				quads = raw.quads,
				center = { cx, cy, cz },
				size = { max[1] - min[1], max[2] - min[2], max[3] - min[3] },
				look = doneLooks[index],
				colors = raw.colors,
				uvs = uvs,
			})
		end
		return meshes
	end

	return (builder :: any) :: Builder
end

return MeshGeometry

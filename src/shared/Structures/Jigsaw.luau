--!strict
--!native
--[[
	Jigsaw assembly: Minecraft 1.20.1's JigsawPlacement, pure and deterministic.

	A jigsaw structure grows from a start piece. Each piece's jigsaw blocks name a template pool;
	a child from that pool is attached to each jigsaw where a jigsaw of the child fits it
	(`canAttach`: facing each other, same top unless the source is rollable, and the source's
	target is the child jigsaw's name) and the child's box fits in the free space. Breadth first,
	up to `maxDepth` levels:

	  - Start (addPieces): a random rotation and a weighted random element of the start pool (an
	    empty element gives no structure). With `startJigsawName`, that jigsaw of the piece sits
	    on the start position. The piece then moves so its layer 0 is the ground's top layer:
	    minY + 1 = startHeight + firstFreeHeight(centre of its box) with `projectToHeightmap`,
	    otherwise minY + 1 = its unprojected y (Minecraft's groundLevelDelta of 1).
	  - Free space: the box centre ± maxDistance (80) in every axis, minus the start piece's box,
	    shared by the whole structure. A jigsaw whose target cell (one step in front of it) is
	    inside its own piece's box uses that piece's own box instead, minus the children already
	    placed in it, and its child (and that child's own outward children) must stay inside it.
	    A box fits when every cell of it is free (Minecraft: the box shrunk by 0.25 is inside the
	    free shape); the placed box is then taken out of the free space.
	  - Children (Placer.tryPlacingChildren): every jigsaw of the piece in shuffled order. The
	    candidates are its pool's elements in a weighted random order (only below maxDepth), then
	    the pool's fallback's: so pieces at maxDepth still get their fallback (end caps). An empty
	    element stops the jigsaw. For each candidate, each rotation in shuffled order and each of
	    its jigsaws that can attach (shuffled), the child's y is:
	      both rigid:     its jigsaw lines up with the source (one step up or down for vertical
	                      jigsaws);
	      otherwise:      its jigsaw sits at firstFreeHeight of the source jigsaw's column
	                      (sampled once per source jigsaw).
	    The first child that fits is kept and the next source jigsaw is tried.
	  - Missing pools are skipped (with a warning, like Minecraft's "Empty or non-existent
	    pool"); "empty" (or "minecraft:empty", or "") is the silent empty pool.

	Shuffles use Util/Hash's rng. Minecraft shuffles a list holding each element `weight` times; an
	element that failed can only fail again for the same jigsaw (nothing changed), so drawing the
	distinct elements one by one with probability proportional to weight (sampling without
	replacement, O(log n) per draw) gives the same outcome and costs far less with large weights.
	Results depend only on the options, so every client and the server assemble the same structure.
	Data made to waste time (huge pools, jigsaws nothing can attach to) is cut short by MAX_WORK.

	Not ported: the expansion hack (legacy villages reserving height above small pieces) and
	junctions (Minecraft's beard terrain adaptation; the generator has its own foundation fill).

	Writing pieces: `localColumn`, `baseY`, `cellBlock` and `blockAt` give the block a piece puts
	in a world cell, after rotation (Blocks.rotate), with jigsaws turned into their final state;
	nil means "leave the world as it is" (outside the piece, structure void).
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Hash = require(script.Parent.Parent.Util.Hash)
local Transform = require(script.Parent.Transform)

-- The parts of a template (Structures/Template) the assembly reads.
export type JigsawData = {
	x: number,
	y: number,
	z: number,
	front: string,
	top: string,
	name: string,
	target: string,
	pool: string,
	finalState: string,
	joint: string,
}
export type Template = {
	name: string,
	size: { number },
	palette: { number },
	cells: buffer,
	jigsaws: { JigsawData },
}

-- template nil = the empty element. projection: "rigid" | "terrain_matching".
export type Element = { template: string?, weight: number, projection: string }
export type Pool = { name: string, fallback: string?, elements: { Element } }

export type Piece = {
	template: string,
	-- Minimum corner of the turned box, world blocks (y: the box's minY; a terrain matching
	-- piece's columns follow the ground instead, see `baseY`).
	x: number,
	y: number,
	z: number,
	rotation: number, -- 0..3 quarter turns clockwise seen from above
	projection: string,
	depth: number, -- 0 for the start piece
	box: { number }, -- minX, minY, minZ, maxX, maxY, maxZ (inclusive)
}

export type Options = {
	seed: number,
	startPool: string,
	startJigsawName: string?,
	-- Start position: the start chunk's minimum corner, and its y (default 0).
	x: number,
	z: number,
	startHeight: number?,
	projectToHeightmap: boolean,
	-- y of the first air above the ground at a column (Minecraft's WORLD_SURFACE_WG height).
	firstFreeHeight: (x: number, z: number) -> number,
	maxDepth: number, -- 0..7
	maxDistance: number?, -- 1..128, default 80
	pool: (name: string) -> Pool?,
	template: (name: string) -> Template?,
	-- Receives each problem once per call (missing pools or templates...). Default: silent.
	warn: ((message: string) -> ())?,
}

-- A jigsaw block in the world, for the jigsaw's Generate button.
export type Source = {
	x: number,
	y: number,
	z: number,
	front: string,
	top: string,
	pool: string,
	target: string,
	joint: string?, -- default: "aligned" for horizontal fronts, "rollable" for vertical ones
}

export type GenerateOptions = {
	seed: number,
	source: Source,
	levels: number, -- 0..7: the depth below the first piece
	maxDistance: number?, -- default 128 (Minecraft's generateJigsaw)
	firstFreeHeight: (x: number, z: number) -> number,
	pool: (name: string) -> Pool?,
	template: (name: string) -> Template?,
	warn: ((message: string) -> ())?,
}

-- A jigsaw for `canAttach` (front and top are direction names; joint nil = the default).
export type Connection = { front: string, top: string, name: string, target: string, joint: string? }

local Jigsaw = {}

Jigsaw.MAX_DEPTH = 7
-- Safety caps for runaway data (thousands of tiny pieces, huge pools, jigsaws nothing attaches
-- to): an assembly stops (with a warning) after this many pieces, or this much work. Work counts
-- every step, whether it leads anywhere or not: each source jigsaw, each candidate drawn and
-- tried in each rotation, each candidate jigsaw tested, each placed box a fit test compares and
-- each ground height read (HEIGHT_WORK). So the cap bounds an assembly's time whatever the data:
-- about 25-35 ms under Lune for the worst shapes tried, while a dense 7 deep village of up to 280
-- pieces needs under 100000 (tests/spec/Jigsaw).
Jigsaw.MAX_PIECES = 4096
Jigsaw.MAX_WORK = 400000
Jigsaw.HEIGHT_WORK = 64
Jigsaw.MAX_DISTANCE = 128
Jigsaw.DEFAULT_DISTANCE = 80
Jigsaw.GENERATE_DISTANCE = 128
Jigsaw.RIGID = "rigid"
Jigsaw.TERRAIN_MATCHING = "terrain_matching"

-- Pool names meaning "nothing", quietly (Minecraft's minecraft:empty).
local EMPTY_POOLS: { [string]: boolean } = { [""] = true, empty = true, ["minecraft:empty"] = true }
Jigsaw.EMPTY_POOLS = table.freeze(EMPTY_POOLS)

local floor = math.floor
local readu16 = buffer.readu16

-- Directions as Minecraft's ordinals + 1: Down, Up, North, South, West, East.
local DIRECTION_INDEX: { [string]: number } = { Down = 1, Up = 2, North = 3, South = 4, West = 5, East = 6 }
local DX = { 0, 0, 0, 0, -1, 1 }
local DY = { -1, 1, 0, 0, 0, 0 }
local DZ = { 0, 0, -1, 1, 0, 0 }
local OPPOSITE = { 2, 1, 4, 3, 6, 5 }
-- One clockwise quarter turn seen from above.
local CLOCKWISE = { 1, 2, 6, 5, 3, 4 }

local function turn(direction: number, rotation: number): number
	for _ = 1, rotation do
		direction = CLOCKWISE[direction]
	end
	return direction
end

-- Whether a jigsaw ignores tops when attaching: its joint, else rollable when it faces up or down.
local function isRollable(joint: string?, front: number): boolean
	if joint == "rollable" then
		return true
	elseif joint == "aligned" then
		return false
	end
	return front <= 2
end

-- Java's (a + b) / 2 (rounds towards zero), as Minecraft centres boxes.
local function midpoint(a: number, b: number): number
	local s = a + b
	return if s >= 0 then s // 2 else -(-s // 2)
end

--[[ Per template data, cached by template (templates are immutable once loaded) ]]

local function inside(j: JigsawData, sx: number, sy: number, sz: number): boolean
	if type(j) ~= "table" then
		return false
	end
	local x, y, z = j.x, j.y, j.z
	return type(x) == "number"
		and type(y) == "number"
		and type(z) == "number"
		and x == floor(x)
		and y == floor(y)
		and z == floor(z)
		and x >= 0
		and x < sx
		and y >= 0
		and y < sy
		and z >= 0
		and z < sz
end

-- A jigsaw of a template turned with its piece.
type Connector = {
	x: number, -- in the turned box
	y: number,
	z: number,
	front: number, -- direction index
	top: number,
	rollable: boolean,
	name: string,
	target: string,
	pool: string,
}

type Info = {
	sx: number,
	sy: number,
	sz: number,
	-- [rotation + 1] = every jigsaw turned, and those with each name.
	turned: { { Connector } },
	named: { { [string]: { Connector } } },
	-- Per rotation (built when first written): the palette after Blocks.rotate, and the jigsaw
	-- cells' final state blocks by cell index (turned too; -1 = keep).
	palettes: { { number } }?,
	finals: { { [number]: number } }?,
}

local infos: { [Template]: Info } = setmetatable({}, { __mode = "k" }) :: any

local function info(template: Template): Info
	local cached = infos[template]
	if cached then
		return cached
	end
	local size = template.size
	local sx, sy, sz = size[1], size[2], size[3]
	local turned: { { Connector } } = {}
	local named: { { [string]: { Connector } } } = {}
	for r = 0, 3 do
		local list: { Connector } = {}
		local byName: { [string]: { Connector } } = {}
		for _, j in template.jigsaws do
			-- (Bad data is reported by Library; such a jigsaw just never connects.)
			local ok = inside(j, sx, sy, sz) and type(j.name) == "string" and type(j.target) == "string"
			local front = if ok then DIRECTION_INDEX[j.front] else nil
			local top = if ok then DIRECTION_INDEX[j.top] else nil
			if front and top then
				local x, y, z = Transform.position(j.x, j.y, j.z, sx, sz, r)
				local c: Connector = {
					x = x,
					y = y,
					z = z,
					front = turn(front, r),
					top = turn(top, r),
					rollable = isRollable(j.joint, front),
					name = j.name,
					target = j.target,
					pool = if type(j.pool) == "string" then j.pool else "",
				}
				table.insert(list, c)
				local same = byName[j.name]
				if same == nil then
					same = {}
					byName[j.name] = same
				end
				table.insert(same, c)
			end
		end
		turned[r + 1] = list
		named[r + 1] = byName
	end
	local result: Info = { sx = sx, sy = sy, sz = sz, turned = turned, named = named }
	infos[template] = result
	return result
end

--[[ Random order helpers ]]

local function shuffle<T>(list: { T }, rng: Hash.Rng)
	-- Fisher-Yates from the end, as java.util.Collections.shuffle / Util.shuffle.
	for i = #list, 2, -1 do
		local j = rng:int(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

local function shuffledCopy<T>(list: { T }, rng: Hash.Rng): { T }
	local copy = table.clone(list)
	shuffle(copy, rng)
	return copy
end

local function weightOf(element: Element): number
	local w = element.weight
	return if type(w) == "number" and w >= 1 then floor(w) else 0
end

-- Per pool, cached (pools are immutable once used): its elements with a weight, their weights,
-- the total, whether any is terrain matching, the highest power of two <= the element count (for
-- weightedOrder's tree), and the work a weighted draw of one element is charged (its steps).
type PoolData = {
	elements: { Element },
	weights: { number },
	total: number,
	terrain: boolean,
	top: number,
	drawWork: number,
}

local poolData: { [Pool]: PoolData } = setmetatable({}, { __mode = "k" }) :: any

local function dataOf(pool: Pool): PoolData
	local data = poolData[pool]
	if data then
		return data
	end
	local elements, weights, total, terrain = {}, {}, 0, false
	for _, e in pool.elements do
		local w = weightOf(e)
		if w > 0 then
			table.insert(elements, e)
			table.insert(weights, w)
			total += w
			terrain = terrain or (e.template ~= nil and e.projection == "terrain_matching")
		end
	end
	local top, steps = 1, 1
	while top * 2 <= #elements do
		top *= 2
		steps += 1
	end
	local built: PoolData = {
		elements = elements,
		weights = weights,
		total = total,
		terrain = terrain,
		top = top,
		drawWork = 1 + steps // 2,
	}
	poolData[pool] = built
	return built
end

-- Weighted random element (Minecraft's getRandomTemplate: uniform over each element repeated
-- `weight` times). nil when the pool has no weight at all.
local function randomElement(data: PoolData, rng: Hash.Rng): Element?
	if data.total <= 0 then
		return nil
	end
	local pick = rng:int(0, data.total - 1)
	for i, w in data.weights do
		pick -= w
		if pick < 0 then
			return data.elements[i]
		end
	end
	return nil
end

-- Distinct elements in weighted random order (sampling without replacement), appended to `out`.
-- Each draw picks the first element left whose running weight passes a random number below the
-- total left; the weights sit in a Fenwick tree (tree[i] sums the weights in (i - lowbit(i), i]),
-- so a draw and the removal cost O(log n) instead of a scan and a shift of the list.
local function weightedOrder(data: PoolData, rng: Hash.Rng, out: { Element })
	local elements, weights = data.elements, data.weights
	local n = #weights
	local tree = table.clone(weights)
	for i = 1, n do
		local parent = i + bit32.band(i, -i)
		if parent <= n then
			tree[parent] += tree[i]
		end
	end
	local top = data.top
	local total = data.total
	while total > 0 do
		-- The last index whose prefix sum is <= pick: the element after it is the one drawn
		-- (removed elements weigh 0, so they are never drawn again).
		local pick = rng:int(0, total - 1)
		local at, step = 0, top
		while step > 0 do
			local probe = at + step
			if probe <= n and tree[probe] <= pick then
				at = probe
				pick -= tree[probe]
			end
			step //= 2
		end
		at += 1
		local w = weights[at]
		table.insert(out, elements[at])
		total -= w
		while at <= n do
			tree[at] -= w
			at += bit32.band(at, -at)
		end
	end
end

-- The 24 orders of the four rotations: a shuffle is one of them, picked uniformly.
local ROTATION_ORDERS: { { number } } = {}
for a = 0, 3 do
	for b = 0, 3 do
		for c = 0, 3 do
			for d = 0, 3 do
				if a ~= b and a ~= c and a ~= d and b ~= c and b ~= d and c ~= d then
					table.insert(ROTATION_ORDERS, { a, b, c, d })
				end
			end
		end
	end
end

--[[
	Free space: a box minus the boxes taken out of it (all inclusive integer boxes). The holes are
	also filed in a grid of CELL × CELL columns over the box, so a fit test only looks at the few
	holes near it (a 7 deep village takes out ~100 boxes and tests ~1000).
]]

local CELL = 16

type Space = {
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
	-- Boxes taken out, 6 numbers each.
	holes: { number },
	-- Grid columns (cx * depth + cz + 1) -> indices into `holes` of the boxes overlapping them.
	cells: { [number]: { number } },
	depth: number, -- grid columns along z
}

local function newSpace(box: { number }): Space
	return {
		minX = box[1],
		minY = box[2],
		minZ = box[3],
		maxX = box[4],
		maxY = box[5],
		maxZ = box[6],
		holes = {},
		cells = {},
		depth = (box[6] - box[3]) // CELL + 1,
	}
end

-- Whether the box is free in `s`. Charges the assembly's work: one, plus one per grid column and
-- per hole it looks at.
local function fits(
	ctx: Context,
	s: Space,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): boolean
	ctx.work -= 1
	local minX, minZ = s.minX, s.minZ
	if x0 < minX or y0 < s.minY or z0 < minZ or x1 > s.maxX or y1 > s.maxY or z1 > s.maxZ then
		return false
	end
	local holes, cells, depth = s.holes, s.cells, s.depth
	local cz0, cz1 = (z0 - minZ) // CELL, (z1 - minZ) // CELL
	for cx = (x0 - minX) // CELL, (x1 - minX) // CELL do
		for cz = cz0, cz1 do
			local list = cells[cx * depth + cz + 1]
			ctx.work -= 1
			if list then
				ctx.work -= #list
				for _, i in list do
					if
						x0 <= holes[i + 3]
						and x1 >= holes[i]
						and y0 <= holes[i + 4]
						and y1 >= holes[i + 1]
						and z0 <= holes[i + 5]
						and z1 >= holes[i + 2]
					then
						return false
					end
				end
			end
		end
	end
	return true
end

local function takeOut(s: Space, box: { number })
	local holes = s.holes
	local n = #holes
	for i = 1, 6 do
		holes[n + i] = box[i]
	end
	-- File it under the grid columns it overlaps (clipped to the space: nothing fits outside).
	local cells, depth = s.cells, s.depth
	local cx0 = math.max(0, (box[1] - s.minX) // CELL)
	local cx1 = math.min((s.maxX - s.minX) // CELL, (box[4] - s.minX) // CELL)
	local cz0 = math.max(0, (box[3] - s.minZ) // CELL)
	local cz1 = math.min(depth - 1, (box[6] - s.minZ) // CELL)
	for cx = cx0, cx1 do
		for cz = cz0, cz1 do
			local key = cx * depth + cz + 1
			local list = cells[key]
			if list == nil then
				list = {}
				cells[key] = list
			end
			table.insert(list, n + 1)
		end
	end
end

--[[ Assembly ]]

type State = { piece: Piece, info: Info, free: Space }

type Context = {
	rng: Hash.Rng,
	maxDepth: number,
	firstFreeHeight: (x: number, z: number) -> number,
	pool: (name: string) -> Pool?,
	template: (name: string) -> Template?,
	warn: (message: string) -> (),
	pieces: { Piece },
	queue: { State },
	work: number, -- left before the assembly stops (see MAX_WORK)
}

-- The terrain's first free height at a column, charged to the work.
local function groundAt(ctx: Context, x: number, z: number): number
	ctx.work -= Jigsaw.HEIGHT_WORK
	return ctx.firstFreeHeight(x, z)
end

local function makeWarn(warn: ((message: string) -> ())?): (message: string) -> ()
	local seen: { [string]: boolean } = {}
	return function(message: string)
		if warn and not seen[message] then
			seen[message] = true
			warn(message)
		end
	end
end

local function templateInfo(ctx: Context, name: string): (Template?, Info?)
	local template = ctx.template(name)
	if template == nil then
		ctx.warn(`Missing template '{name}'`)
		return nil, nil
	end
	return template, info(template)
end

-- The pool and fallback a jigsaw points at (fallback nil: none). nil when Minecraft skips the
-- jigsaw: the empty pool (quietly), a missing pool or fallback (with a warning).
local function pools(ctx: Context, poolName: string): (PoolData?, PoolData?)
	if EMPTY_POOLS[poolName] then
		return nil, nil
	end
	local pool = ctx.pool(poolName)
	if pool == nil or #pool.elements == 0 then
		ctx.warn(`Empty or non-existent pool: {poolName}`)
		return nil, nil
	end
	local fallbackName = pool.fallback
	if fallbackName ~= nil and not EMPTY_POOLS[fallbackName] then
		local fallback = ctx.pool(fallbackName)
		if fallback == nil or #fallback.elements == 0 then
			ctx.warn(`Empty or non-existent fallback pool: {fallbackName}`)
			return nil, nil
		end
		return dataOf(pool), dataOf(fallback)
	end
	return dataOf(pool), nil
end

-- The candidates: the pool's elements in weighted random order (`withPool`), then the fallback's.
-- Each draw is charged to the work.
local function candidates(ctx: Context, pool: PoolData, fallback: PoolData?, withPool: boolean): { Element }
	local list: { Element } = {}
	if withPool then
		weightedOrder(pool, ctx.rng, list)
		ctx.work -= #pool.elements * pool.drawWork
	end
	if fallback then
		weightedOrder(fallback, ctx.rng, list)
		ctx.work -= #fallback.elements * fallback.drawWork
	end
	return list
end

--[[
	Tries the candidates for one source jigsaw at world (jx, jy, jz). `parentMinY` and
	`parentRigid` describe the piece it belongs to (a world jigsaw counts as rigid with its own y as
	minY). A child's jigsaw always lands in the source's target cell: at the source's level when
	both are rigid (`levelFree`: whether that cell is free), else at the ground's height (`ground`,
	`groundFree`; nil until needed). A candidate whose cell is taken cannot fit in any rotation, so
	it is skipped untried. Every candidate, rotation and jigsaw tried is charged to the work, and
	the search gives up when the work runs out. Returns the placed child, or nil.
]]
local function attach(
	ctx: Context,
	list: { Element },
	source: Connector,
	jx: number,
	jy: number,
	jz: number,
	parentMinY: number,
	parentRigid: boolean,
	space: Space?,
	depth: number,
	levelFree: boolean,
	ground: number?,
	groundFree: boolean?
): (Piece?, Info?)
	local rng = ctx.rng
	local front = source.front
	local tx, tz = jx + DX[front], jz + DZ[front]
	local j = jy - parentMinY
	local want = OPPOSITE[front]
	for _, element in list do
		local name = element.template
		if name == nil then
			-- The empty element: this jigsaw stays as it is.
			break
		end
		ctx.work -= 1
		if ctx.work <= 0 then
			break
		end
		local childRigid = element.projection ~= Jigsaw.TERRAIN_MATCHING
		local aligned = parentRigid and childRigid
		if not aligned and groundFree == nil then
			ground = groundAt(ctx, jx, jz)
			groundFree = space == nil or fits(ctx, space :: Space, tx, ground :: number, tz, tx, ground :: number, tz)
		end
		if if aligned then not levelFree else not groundFree then
			continue
		end
		local _, cinfo = templateInfo(ctx, name)
		if cinfo then
			for _, r in ROTATION_ORDERS[rng:int(1, 24)] do
				ctx.work -= 1
				local matches = cinfo.named[r + 1][source.target]
				if matches then
					local order: { Connector } = if #matches > 1 then shuffledCopy(matches, rng) else matches
					ctx.work -= #order
					for _, c in order do
						if ctx.work <= 0 then
							return nil, nil
						end
						if c.front == want and (source.rollable or source.top == c.top) then
							local j1 = c.y
							local cy = if aligned then parentMinY + (j - j1 + DY[front]) else (ground :: number) - j1
							local cx, cz = tx - c.x, tz - c.z
							local wx, wy, wz = Transform.size(cinfo.sx, cinfo.sy, cinfo.sz, r)
							local x1, y1, z1 = cx + wx - 1, cy + wy - 1, cz + wz - 1
							if space == nil or fits(ctx, space, cx, cy, cz, x1, y1, z1) then
								local box = { cx, cy, cz, x1, y1, z1 }
								if space then
									takeOut(space, box)
								end
								local piece: Piece = {
									template = name,
									x = cx,
									y = cy,
									z = cz,
									rotation = r,
									projection = if childRigid then Jigsaw.RIGID else Jigsaw.TERRAIN_MATCHING,
									depth = depth,
									box = box,
								}
								return piece, cinfo
							end
						end
					end
				end
			end
		end
	end
	return nil, nil
end

-- Placer.tryPlacingChildren for one queued piece.
local function placeChildren(ctx: Context, state: State)
	local piece, pinfo = state.piece, state.info
	local box = piece.box
	local minY = box[2]
	local rigid = piece.projection ~= Jigsaw.TERRAIN_MATCHING
	local depth = piece.depth
	local withPool = depth ~= ctx.maxDepth
	local inner: Space? = nil
	for _, source in shuffledCopy(pinfo.turned[piece.rotation + 1], ctx.rng) do
		ctx.work -= 1
		if ctx.work <= 0 or #ctx.pieces >= Jigsaw.MAX_PIECES then
			return
		end
		local pool, fallback = pools(ctx, source.pool)
		if pool == nil or (not withPool and fallback == nil) then
			continue
		end
		local jx, jy, jz = piece.x + source.x, piece.y + source.y, piece.z + source.z
		local front = source.front
		local tx, ty, tz = jx + DX[front], jy + DY[front], jz + DZ[front]
		local space: Space
		if tx >= box[1] and tx <= box[4] and ty >= box[2] and ty <= box[5] and tz >= box[3] and tz <= box[6] then
			-- Pointing into its own piece: the child must fit in what is left of the piece.
			if inner == nil then
				inner = newSpace(box)
			end
			space = inner :: Space
		else
			space = state.free
		end
		-- When the target cell is taken at every height a child could use, nothing can attach:
		-- skip the jigsaw without drawing candidates (most jigsaws pointing back at their parent).
		local levelFree = rigid and fits(ctx, space, tx, ty, tz, tx, ty, tz)
		local ground: number? = nil
		local groundFree: boolean? = nil
		if not levelFree then
			local terrain = not rigid or (withPool and pool.terrain) or (fallback ~= nil and fallback.terrain)
			if terrain then
				ground = groundAt(ctx, jx, jz)
				groundFree = fits(ctx, space, tx, ground :: number, tz, tx, ground :: number, tz)
			end
			if not groundFree then
				continue
			end
		end
		local list = candidates(ctx, pool, fallback, withPool)
		local child, cinfo =
			attach(ctx, list, source, jx, jy, jz, minY, rigid, space, depth + 1, levelFree, ground, groundFree)
		if child and cinfo then
			table.insert(ctx.pieces, child)
			if depth + 1 <= ctx.maxDepth then
				table.insert(ctx.queue, { piece = child, info = cinfo, free = space })
			end
		end
	end
end

local function run(ctx: Context)
	-- Breadth first: placeChildren appends to the queue while it is walked.
	local queue = ctx.queue
	local head = 1
	while head <= #queue do
		local state = queue[head]
		head += 1
		placeChildren(ctx, state)
		if ctx.work <= 0 or #ctx.pieces >= Jigsaw.MAX_PIECES then
			ctx.warn(`Assembly stopped at {#ctx.pieces} pieces: the structure is too big`)
			break
		end
	end
end

-- Options from callers, made safe: whole numbers in range (NaN counts as the lowest).
local function clampDepth(depth: number): number
	return if depth == depth then math.clamp(floor(depth), 0, Jigsaw.MAX_DEPTH) else 0
end

local function clampDistance(distance: number?, default: number): number
	local d = distance or default
	return if d == d then math.clamp(floor(d), 1, Jigsaw.MAX_DISTANCE) else 1
end

-- Seeds must be finite whole numbers for the rng.
local function seedOf(seed: number): number
	return if seed == seed and math.abs(seed) < 2 ^ 52 then floor(seed) else 0
end

--[[
	Assembles the structure starting at (x, startHeight, z). Returns its pieces, the start piece
	first; empty when the start element is empty or the start pool or template is missing.
]]
function Jigsaw.assemble(options: Options): { Piece }
	local rng = Hash.rng(seedOf(options.seed))
	local warn = makeWarn(options.warn)
	local pieces: { Piece } = {}

	-- (Minecraft draws the rotation before the element.)
	local rotation = rng:int(0, 3)
	local startPool = options.pool(options.startPool)
	if startPool == nil then
		warn(`Empty or non-existent start pool: {options.startPool}`)
		return pieces
	end
	local element = randomElement(dataOf(startPool), rng)
	if element == nil then
		warn(`Empty or non-existent start pool: {options.startPool}`)
		return pieces
	end
	local name = element.template
	if name == nil then
		return pieces
	end
	local template = options.template(name)
	if template == nil then
		warn(`Missing template '{name}'`)
		return pieces
	end
	local sinfo = info(template)

	-- Offset of the start jigsaw in the turned piece (0 without one).
	local ox, oy, oz = 0, 0, 0
	local jigsawName = options.startJigsawName
	if jigsawName ~= nil then
		local named = sinfo.named[rotation + 1][jigsawName]
		if named == nil then
			warn(`No starting jigsaw {jigsawName} found in start pool {options.startPool}`)
			return pieces
		end
		local c = named[rng:int(1, #named)]
		ox, oy, oz = c.x, c.y, c.z
	end

	local startY = options.startHeight or 0
	local px, py, pz = options.x - ox, startY - oy, options.z - oz
	local wx, wy, wz = Transform.size(sinfo.sx, sinfo.sy, sinfo.sz, rotation)
	local cx, cz = midpoint(px, px + wx - 1), midpoint(pz, pz + wz - 1)
	-- The piece moves so minY + groundLevelDelta (1) = k: with the projection, its layer 0 is the
	-- ground's top layer; without, it drops one block (as Minecraft's does).
	local k = if options.projectToHeightmap then startY + options.firstFreeHeight(cx, cz) else py
	py = k - 1
	local start: Piece = {
		template = name,
		x = px,
		y = py,
		z = pz,
		rotation = rotation,
		projection = if element.projection == Jigsaw.TERRAIN_MATCHING then Jigsaw.TERRAIN_MATCHING else Jigsaw.RIGID,
		depth = 0,
		box = { px, py, pz, px + wx - 1, py + wy - 1, pz + wz - 1 },
	}
	table.insert(pieces, start)

	local maxDepth = clampDepth(options.maxDepth)
	if maxDepth > 0 then
		local d = clampDistance(options.maxDistance, Jigsaw.DEFAULT_DISTANCE)
		local cy = k + oy
		local outer = newSpace({ cx - d, cy - d, cz - d, cx + d, cy + d, cz + d })
		takeOut(outer, start.box)
		local ctx: Context = {
			rng = rng,
			maxDepth = maxDepth,
			firstFreeHeight = options.firstFreeHeight,
			pool = options.pool,
			template = options.template,
			warn = warn,
			pieces = pieces,
			queue = { { piece = start, info = sinfo, free = outer } },
			work = Jigsaw.MAX_WORK,
		}
		run(ctx)
	end
	return pieces
end

--[[
	The jigsaw block's Generate button: grows a structure from a jigsaw block in the world. The
	first piece comes from the source's pool (then its fallback) and attaches to the source like a
	child would (facing it, its jigsaw named the source's target; rigid pieces line up with it,
	terrain matching ones sit on the ground at the source's column). Then `levels` levels of
	children grow from it as in `assemble`, inside its box centre ± maxDistance (128).
	Returns the pieces, the first one at depth 0; empty when nothing can attach.
]]
function Jigsaw.generateFrom(options: GenerateOptions): { Piece }
	local rng = Hash.rng(seedOf(options.seed))
	local warn = makeWarn(options.warn)
	local pieces: { Piece } = {}
	local source = options.source
	local front, top = DIRECTION_INDEX[source.front], DIRECTION_INDEX[source.top]
	if front == nil or top == nil then
		warn(`Bad jigsaw orientation {source.front} / {source.top}`)
		return pieces
	end
	local connector: Connector = {
		x = source.x,
		y = source.y,
		z = source.z,
		front = front,
		top = top,
		rollable = isRollable(source.joint, front),
		name = "",
		target = source.target,
		pool = source.pool,
	}
	local maxDepth = clampDepth(options.levels)
	local ctx: Context = {
		rng = rng,
		maxDepth = maxDepth,
		firstFreeHeight = options.firstFreeHeight,
		pool = options.pool,
		template = options.template,
		warn = warn,
		pieces = pieces,
		queue = {},
		work = Jigsaw.MAX_WORK,
	}
	local pool, fallback = pools(ctx, source.pool)
	if pool == nil then
		return pieces
	end
	local list = candidates(ctx, pool, fallback, true)
	local first, finfo =
		attach(ctx, list, connector, source.x, source.y, source.z, source.y, true, nil, 0, true, nil, nil)
	if first == nil or finfo == nil then
		warn(
			if ctx.work <= 0
				then "Assembly stopped at 0 pieces: the structure is too big"
				else `Nothing in pool {source.pool} has a jigsaw named '{source.target}' that fits this one`
		)
		return pieces
	end
	table.insert(pieces, first)
	if maxDepth > 0 then
		local d = clampDistance(options.maxDistance, Jigsaw.GENERATE_DISTANCE)
		local box = first.box
		local cx, cz = midpoint(box[1], box[4]), midpoint(box[3], box[6])
		local cy = source.y + DY[front]
		local outer = newSpace({ cx - d, cy - d, cz - d, cx + d, cy + d, cz + d })
		takeOut(outer, box)
		-- The source's own cell is taken: nothing grows back over the structure it belongs to.
		takeOut(outer, { source.x, source.y, source.z, source.x, source.y, source.z })
		table.insert(ctx.queue, { piece = first, info = finfo, free = outer })
		run(ctx)
	end
	return pieces
end

-- Minecraft's JigsawBlock.canAttach: `a` is the source, `b` the candidate.
function Jigsaw.canAttach(a: Connection, b: Connection): boolean
	local fa, fb = DIRECTION_INDEX[a.front], DIRECTION_INDEX[b.front]
	if fa == nil or fb == nil then
		return false
	end
	return fa == OPPOSITE[fb] and (isRollable(a.joint, fa) or a.top == b.top) and a.target == b.name
end

-- Union of the pieces' boxes { minX, minY, minZ, maxX, maxY, maxZ }, nil for no pieces.
function Jigsaw.bounds(pieces: { Piece }): { number }?
	local first = pieces[1]
	if first == nil then
		return nil
	end
	local b = table.clone(first.box)
	for i = 2, #pieces do
		local p = pieces[i].box
		for a = 1, 3 do
			b[a] = math.min(b[a], p[a])
			b[a + 3] = math.max(b[a + 3], p[a + 3])
		end
	end
	return b
end

--[[ Writing pieces ]]

-- How Minecraft-style names are matched (final state blocks, Library's biomes): lower case,
-- without "minecraft:", underscores and spaces ("minecraft:oak_planks" and "OakPlanks" are alike).
function Jigsaw.nameKey(name: string): string
	local key = string.lower(name)
	if string.sub(key, 1, 10) == "minecraft:" then
		key = string.sub(key, 11)
	end
	return (string.gsub(key, "[_%s]", ""))
end

-- Block ids by name key, for final states.
local blockByKey: { [string]: number }? = nil
local blockKey = Jigsaw.nameKey

-- Block id of a final state name; -1 for structure void ("keep"); air when unknown.
function Jigsaw.finalStateBlock(name: string): number
	local map = blockByKey
	if map == nil then
		local built: { [string]: number } = {}
		for id = 0, Blocks.count - 1 do
			built[blockKey(Blocks.get(id).name)] = id
		end
		-- (Final states saved before a block was renamed.)
		for old, new in Blocks.RENAMED do
			local key = blockKey(old)
			local renamed = Blocks.find(new)
			if built[key] == nil and renamed ~= nil then
				built[key] = renamed
			end
		end
		map = built
		blockByKey = built
	end
	local id = (map :: { [string]: number })[blockKey(name)]
	if id == nil then
		return Blocks.AIR
	end
	return if Blocks.get(id).name == "StructureVoid" then -1 else id
end

local function writeData(template: Template, i: Info): ({ { number } }, { { [number]: number } })
	local palettes = i.palettes
	local finals = i.finals
	if palettes and finals then
		return palettes, finals
	end
	local unturned: { [number]: number } = {}
	for _, j in template.jigsaws do
		if inside(j, i.sx, i.sy, i.sz) then
			local name = j.finalState
			unturned[(j.y * i.sz + j.z) * i.sx + j.x] = if type(name) == "string"
				then Jigsaw.finalStateBlock(name)
				else Blocks.AIR
		end
	end
	local builtPalettes: { { number } } = {}
	local builtFinals: { { [number]: number } } = {}
	for r = 0, 3 do
		local list = table.create(#template.palette)
		for p, id in template.palette do
			list[p] = Blocks.rotate(id, r, "none")
		end
		builtPalettes[r + 1] = list
		local turned = {}
		for index, block in unturned do
			turned[index] = if block < 0 then block else Blocks.rotate(block, r, "none")
		end
		builtFinals[r + 1] = turned
	end
	i.palettes = builtPalettes
	i.finals = builtFinals
	return builtPalettes, builtFinals
end

--[[
	For hot loops writing a piece: its palette turned by the piece's rotation (cell value v > 0 is
	palette[v]; 0 is keep), and its jigsaw cells' final blocks by cell index (turned; -1 = keep),
	which replace the palette's block unless jigsaws are kept. Cell index = (ly * sz + lz) * sx +
	lx in the template; read the value with buffer.readu16(template.cells, index * 2). Read only.
]]
function Jigsaw.writeTables(piece: Piece, template: Template): ({ number }, { [number]: number })
	local palettes, finals = writeData(template, info(template))
	local r = piece.rotation % 4 + 1
	return palettes[r], finals[r]
end

-- Template-local column (lx, lz) of world column (x, z), or nil outside the piece.
function Jigsaw.localColumn(piece: Piece, template: Template, x: number, z: number): (number?, number?)
	local box = piece.box
	if x < box[1] or x > box[4] or z < box[3] or z > box[6] then
		return nil, nil
	end
	local size = template.size
	local lx, _, lz = Transform.inverse(x - piece.x, 0, z - piece.z, size[1], size[3], piece.rotation)
	return lx, lz
end

-- World y of the piece's layer 0 in a column whose first free height is `height`: the box's minY
-- for a rigid piece; height - 1 for a terrain matching one (Minecraft's GravityProcessor
-- WORLD_SURFACE_WG, offset -1), so its layer 0 replaces the ground's top block.
function Jigsaw.baseY(piece: Piece, height: number): number
	return if piece.projection == Jigsaw.TERRAIN_MATCHING then height - 1 else piece.y
end

-- Block the piece writes at template cell (lx, ly, lz): turned by the piece's rotation, jigsaws
-- become their final state (unless `keepJigsaws`). nil = keep the world's block (structure void).
function Jigsaw.cellBlock(
	piece: Piece,
	template: Template,
	lx: number,
	ly: number,
	lz: number,
	keepJigsaws: boolean?
): number?
	local i = info(template)
	local index = (ly * i.sz + lz) * i.sx + lx
	local p = readu16(template.cells, index * 2)
	if p == 0 then
		return nil
	end
	local palettes, finals = writeData(template, i)
	local r = piece.rotation % 4 + 1
	if not keepJigsaws then
		local final = finals[r][index]
		if final ~= nil then
			return if final < 0 then nil else final
		end
	end
	return palettes[r][p]
end

-- Block the piece writes at world cell (x, y, z), nil = nothing (outside it, or keep).
-- `firstFreeHeight` is only called for terrain matching pieces.
function Jigsaw.blockAt(
	piece: Piece,
	template: Template,
	x: number,
	y: number,
	z: number,
	firstFreeHeight: (x: number, z: number) -> number,
	keepJigsaws: boolean?
): number?
	local lx, lz = Jigsaw.localColumn(piece, template, x, z)
	if lx == nil or lz == nil then
		return nil
	end
	local base = if piece.projection == Jigsaw.TERRAIN_MATCHING then firstFreeHeight(x, z) - 1 else piece.y
	local ly = y - base
	if ly < 0 or ly >= template.size[2] then
		return nil
	end
	return Jigsaw.cellBlock(piece, template, lx, ly, lz, keepJigsaws)
end

-- Calls `fn(x, y, z, block)` for every cell the piece writes (keep cells skipped), column by
-- column. For placing pieces in a live world (the Generate button).
function Jigsaw.eachBlock(
	piece: Piece,
	template: Template,
	firstFreeHeight: (x: number, z: number) -> number,
	fn: (x: number, y: number, z: number, block: number) -> (),
	keepJigsaws: boolean?
)
	local box = piece.box
	local sy = template.size[2]
	for x = box[1], box[4] do
		for z = box[3], box[6] do
			local lx, lz = Jigsaw.localColumn(piece, template, x, z)
			if lx and lz then
				local base = if piece.projection == Jigsaw.TERRAIN_MATCHING then firstFreeHeight(x, z) - 1 else piece.y
				for ly = 0, sy - 1 do
					local block = Jigsaw.cellBlock(piece, template, lx, ly, lz, keepJigsaws)
					if block ~= nil then
						fn(x, base + ly, z, block)
					end
				end
			end
		end
	end
end

return Jigsaw

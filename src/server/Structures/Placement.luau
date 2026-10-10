--!strict
--[[
	Placing structures in the live world: a structure block's LOAD and a jigsaw's Generate. Pure,
	so the tests can run it.

	A plan is the list of cells to set, in the order they are set, with what else each cell gets
	once its block is there (`Extra`: a jigsaw's settings, a DATA structure block's, a container's
	items). A LOAD's plan (at most 48 x 48 x 48 cells) is built in one go; a Generate's (up to
	millions of cells) is streamed: it hands the queue its cells a batch at a time as they are
	placed (`refill`), so neither its building nor its memory grows with its size. The queue
	places a few thousand blocks a frame (Config.Structures.LoadBlocksPerFrame), so a big
	structure never stalls the server.

	LOAD (`loadPlan`, Minecraft's StructureTemplate.placeInWorld from a structure block):
	  * the template turned by its mirror then its rotation around Minecraft's pivot: the position
	    given (the structure block + its relative position) is where the template's local (0, 0, 0)
	    lands, and the turned box extends from there as Minecraft's does (Transform.anchor);
	  * every cell but "keep" (structure void) is placed: air clears the world;
	  * blocks turn with the structure (Blocks.rotate: wall torches, glow lichen, jigsaws);
	  * jigsaws keep their settings, data markers come back as DATA structure blocks with their
	    string, and container blocks get the items the template holds for them (an empty one is
	    emptied, as Minecraft clears a container it places over);
	  * integrity below 1 places each cell with that chance (Minecraft's BlockRotProcessor, one
	    seeded random draw per cell in template order), from `seed`.
	Generate (`piecesPlan`, JigsawPlacement.generateJigsaw): every piece's cells (Structures/
	Jigsaw's cell blocks: turned, jigsaws as their final state unless kept, structure void kept;
	terrain matching columns on the ground), where pieces overlap (a child inside its parent's
	box) the later piece's cell replaces the earlier one's: the earlier one is never set. Kept
	jigsaws keep their settings, containers get their items; data markers stay air. Streamed in
	stages, each resumable at any cell: the terrain matching pieces' column heights, then the
	solid blocks layer by layer over all pieces, then the late ones piece by piece.

	Order: solid blocks first, bottom up, then the blocks that hang on, stand on or flow from
	others (torches, lanterns, glow lichen, plants, fluids), column by column, bottom up, so what
	holds them is there before them and a tall plant's two halves are set together.

	The queue (`newQueue`, `Queue.step`) sets cells through its `Env`, at most `blocks` cells,
	`chunks` chunk generations and (optionally) `seconds` a step, plans in the order they were
	added (a streamed plan's batches as the step reaches them, within the same budgets). It never
	stops between a tall plant's lower half and its upper half (the Plant behaviour would pop a
	half alone).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local Jigsaw = require(Shared.Structures.Jigsaw)
local Machines = require(Shared.Machines)
local Protocol = require(Shared.Net.Protocol)
local Settings = require(Shared.Structures.Settings)
local Template = require(Shared.Structures.Template)
local Transform = require(Shared.Structures.Transform)

type Template = Template.Template

export type Extra = {
	-- A jigsaw's settings, set once the jigsaw is there.
	jigsaw: Settings.JigsawSettings?,
	-- A structure block's settings (a data marker's DATA block).
	structure: Settings.StructureSettings?,
	-- What a container holds afterwards (Template items: slot, item name, count, damage).
	items: { Template.ContainerItem }?,
}

export type Plan = {
	-- x, y, z, block of each cell, in placing order (a streamed plan: of its current batch).
	cells: { number },
	count: number,
	-- What else cell i (1-based) gets.
	extras: { [number]: Extra },
	-- A streamed plan: puts its next batch in `cells`, `count` and `extras` after visiting at most
	-- about `visits` template cells (the batch may be empty); false once it has no more cells.
	refill: ((plan: Plan, visits: number) -> boolean)?,
	-- A streamed plan: how many cells may still come after this batch (at most).
	upcoming: number?,
}

export type LoadOptions = {
	-- Where the template's local (0, 0, 0) goes: the structure block plus its relative position.
	x: number,
	y: number,
	z: number,
	rotation: number,
	mirror: string,
	integrity: number,
	-- Seeds the integrity draws (any whole number).
	seed: number,
}

-- How the queue changes the world.
export type Env = {
	-- Sets block (x, y, z) (generating its chunk if need be).
	setBlock: (x: number, y: number, z: number, block: number) -> (),
	-- Is the chunk of column (x, z) generated? `load` generates it.
	loaded: (x: number, z: number) -> boolean,
	load: (x: number, z: number) -> (),
	-- Cell (x, y, z) was just set to `block`, which has `extra` too.
	extra: (x: number, y: number, z: number, block: number, extra: Extra) -> (),
	-- A clock in seconds (os.clock) when the step has a time budget too.
	clock: (() -> number)?,
}

export type Queue = {
	plans: { Plan },
	-- Cells of the first plan already placed.
	done: number,
	add: (self: Queue, plan: Plan) -> (),
	-- Cells still to place.
	pending: (self: Queue) -> number,
	step: (self: Queue, blocks: number, chunks: number, env: Env, seconds: number?) -> number,
}

local HEIGHT = Config.WorldHeight
local LIMIT = Protocol.MAX_COORDINATE
local OFFSET = 1048576 -- 2^20
local SPAN = 2097152 -- 2^21

local Placement = {}

-- Cells in a streamed plan's batch (a little more to keep a tall plant whole).
Placement.BATCH = 256

-- Cells placed between looks at the clock (a step's time budget).
local TIME_CHECK = 64
-- A streamed plan's batches: template cells one may visit (most visits are cheap; a terrain
-- matching column's height counts HEIGHT_VISITS), and the queue looks at the clock after each.
local REFILL_VISITS = 4096
local HEIGHT_VISITS = 16
-- Columns of the grid that finds overlapping pieces (blocks).
local GRID = 16

-- Placed after the solid blocks: what hangs on, stands on or flows from another block (both halves
-- of a door too, so its upper half follows its lower half as a tall plant's does).
local LATE: { boolean } = {}
for block = 0, Blocks.count - 1 do
	local def = Blocks.get(block)
	LATE[block + 1] = def.support ~= nil or def.plant ~= nil or def.fluid ~= nil or def.door ~= nil
end
local function late(block: number): boolean
	return LATE[block + 1] == true
end

local function isContainer(block: number): boolean
	return Machines.containerSize(block) > 0
end

-- A template's records by cell index.
local function byCell<T>(t: Template, list: { T }): { [number]: T }
	local map: { [number]: T } = {}
	for _, r in list do
		local record = r :: any
		if Template.inside(t, record.x, record.y, record.z) then
			map[Template.index(t, record.x, record.y, record.z)] = r
		end
	end
	return map
end

local function jigsawSettings(j: Template.Jigsaw): Settings.JigsawSettings
	return Settings.clampJigsaw({
		name = j.name,
		target = j.target,
		pool = j.pool,
		finalState = j.finalState,
		joint = j.joint,
	}, j.front)
end

--[[
	What a template places with a structure block's LOAD at `options` (see the header). Cells
	outside the world (above or below it, beyond Protocol.MAX_COORDINATE) are left out.
]]
function Placement.loadPlan(t: Template, options: LoadOptions): Plan
	local sx, sy, sz = t.size[1], t.size[2], t.size[3]
	local rotation = math.floor(options.rotation) % 4
	local mirror: Transform.Mirror = if options.mirror == "leftRight"
		then "leftRight"
		elseif options.mirror == "frontBack" then "frontBack"
		else "none"
	local dx, dz = Transform.anchor(sx, sz, rotation, mirror)
	local ox, oy, oz = options.x + dx, options.y, options.z + dz
	local integrity = math.clamp(options.integrity, 0, 1)
	local rng = Hash.rng(options.seed)
	local jigsaws = byCell(t, t.jigsaws)
	local markers = byCell(t, t.markers)
	local containers = byCell(t, t.containers)
	local dataBlock = Blocks.structureBlock("data") :: number
	local lut = Blocks.rotateLut(rotation, mirror)
	local cells, palette = t.cells, t.palette

	-- Each palette entry turned, and whether it goes in the second pass.
	local turned: { number } = table.create(#palette)
	local isLate: { boolean } = table.create(#palette)
	for p, block in palette do
		turned[p] = buffer.readu16(lut, block * 2)
		isLate[p] = late(turned[p])
	end

	-- Which cells are placed (1) or late (2): keep cells, integrity's draws (Minecraft's
	-- BlockRotProcessor: nextFloat() > integrity skips the block; one draw per cell in template
	-- order) and cells outside the world are 0.
	local volume = sx * sy * sz
	local pass = buffer.create(volume)
	for ly = 0, sy - 1 do
		local y = oy + ly
		local inWorld = y >= 0 and y < HEIGHT
		for lz = 0, sz - 1 do
			for lx = 0, sx - 1 do
				local index = (ly * sz + lz) * sx + lx
				local p = buffer.readu16(cells, index * 2)
				if p == 0 or (integrity < 1 and rng:float() >= integrity) or not inWorld then
					continue
				end
				local tx, _, tz = Transform.position(lx, ly, lz, sx, sz, rotation, mirror)
				if math.abs(ox + tx) > LIMIT or math.abs(oz + tz) > LIMIT then
					continue
				end
				buffer.writeu8(pass, index, if isLate[p] and markers[index] == nil then 2 else 1)
			end
		end
	end

	local list = table.create(volume * 4)
	local extras: { [number]: Extra } = {}
	local count = 0
	local function emit(lx: number, ly: number, lz: number, index: number)
		local block = turned[buffer.readu16(cells, index * 2)]
		local extra: Extra? = nil
		local marker = markers[index]
		local jigsaw = jigsaws[index]
		if marker then
			block = dataBlock
			local settings = Settings.defaultStructure("data")
			settings.metadata = Settings.cut(marker.data, Settings.MAX_METADATA)
			extra = { structure = settings }
		elseif jigsaw and Blocks.isJigsaw(block) then
			extra = { jigsaw = jigsawSettings(jigsaw) }
		elseif isContainer(block) then
			local record = containers[index]
			extra = { items = if record then record.items else {} }
		end
		local tx, ty, tz = Transform.position(lx, ly, lz, sx, sz, rotation, mirror)
		count += 1
		local o = (count - 1) * 4
		list[o + 1], list[o + 2], list[o + 3], list[o + 4] = ox + tx, oy + ty, oz + tz, block
		if extra then
			extras[count] = extra
		end
	end
	-- Solid blocks layer by layer, bottom up...
	for ly = 0, sy - 1 do
		for lz = 0, sz - 1 do
			for lx = 0, sx - 1 do
				local index = (ly * sz + lz) * sx + lx
				if buffer.readu8(pass, index) == 1 then
					emit(lx, ly, lz, index)
				end
			end
		end
	end
	-- ...then what hangs on, stands on or flows from them, column by column, bottom up.
	for lz = 0, sz - 1 do
		for lx = 0, sx - 1 do
			for ly = 0, sy - 1 do
				local index = (ly * sz + lz) * sx + lx
				if buffer.readu8(pass, index) == 2 then
					emit(lx, ly, lz, index)
				end
			end
		end
	end
	return { cells = list, count = count, extras = extras }
end

--[[ Generate: a streamed plan ]]

-- A piece of a Generate plan and what streaming it needs.
type Part = {
	piece: Jigsaw.Piece,
	template: Template,
	sx: number,
	sy: number,
	sz: number,
	-- Its place in the plan's pieces (later ones replace it where they overlap).
	rank: number,
	-- Its palette turned by its rotation, and its jigsaw cells' final blocks (Jigsaw.writeTables).
	palette: { number },
	finals: { [number]: number },
	jigsaws: { [number]: Template.Jigsaw },
	containers: { [number]: Template.Container },
	-- World y of each column's layer 0 (i32 per column lz * sx + lx) for a terrain matching piece,
	-- once the heights stage got there; a rigid piece's is piece.y.
	bases: buffer?,
	-- World layers it covers (within the world; minY > maxY when none).
	minY: number,
	maxY: number,
	-- Later pieces whose columns overlap its own: where they set a block, it sets none.
	later: { Part },
}

-- The block `part` sets at template cell (lx, ly, lz) (Jigsaw.cellBlock), nil = keep.
local function blockOf(part: Part, index: number, keepJigsaws: boolean): number?
	local p = buffer.readu16(part.template.cells, index * 2)
	if p == 0 then
		return nil
	end
	if not keepJigsaws then
		local final = part.finals[index]
		if final ~= nil then
			return if final < 0 then nil else final
		end
	end
	return part.palette[p]
end

local function baseOf(part: Part, column: number): number
	local bases = part.bases
	return if bases then buffer.readi32(bases, column * 4) else part.piece.y
end

-- Does a later piece set a block at world (x, y, z)? Then `part`'s cell there is not placed.
local function replaced(part: Part, x: number, y: number, z: number, keepJigsaws: boolean): boolean
	for _, other in part.later do
		local box = other.piece.box
		if x < box[1] or x > box[4] or z < box[3] or z > box[6] or y < other.minY or y > other.maxY then
			continue
		end
		local lx, lz = Jigsaw.localColumn(other.piece, other.template, x, z)
		if lx == nil or lz == nil then
			continue
		end
		local column = lz * other.sx + lx
		local ly = y - baseOf(other, column)
		if ly >= 0 and ly < other.sy and blockOf(other, (ly * other.sz + lz) * other.sx + lx, keepJigsaws) ~= nil then
			return true
		end
	end
	return false
end

-- What else a cell gets: a kept jigsaw its settings, a container its items.
local function extraOf(part: Part, index: number, block: number): Extra?
	local jigsaw = part.jigsaws[index]
	if jigsaw and Blocks.isJigsaw(block) then
		return { jigsaw = jigsawSettings(jigsaw) }
	elseif isContainer(block) then
		local record = part.containers[index]
		return { items = if record then record.items else {} }
	end
	return nil
end

--[[
	What a jigsaw's Generate places: `pieces` (Jigsaw.generateFrom) of the templates `template`
	finds, terrain matching columns on `firstFreeHeight` (the y of the first air above the ground,
	asked as the plan reaches them), jigsaws turned into their final state unless `keepJigsaws`
	(then they keep their settings). Pieces whose template is missing are skipped. A streamed plan
	(see the header): building it here only finds which pieces overlap, its cells come as the
	queue places them.
]]
function Placement.piecesPlan(
	pieces: { Jigsaw.Piece },
	template: (name: string) -> Template?,
	firstFreeHeight: (x: number, z: number) -> number,
	keepJigsaws: boolean
): Plan
	local parts: { Part } = {}
	local total = 0
	for _, piece in pieces do
		local t = template(piece.template)
		if t == nil then
			continue
		end
		local sx, sy, sz = t.size[1], t.size[2], t.size[3]
		local palette, finals = Jigsaw.writeTables(piece, t)
		local terrain = piece.projection == Jigsaw.TERRAIN_MATCHING
		table.insert(parts, {
			piece = piece,
			template = t,
			sx = sx,
			sy = sy,
			sz = sz,
			rank = #parts + 1,
			palette = palette,
			finals = finals,
			jigsaws = if keepJigsaws then byCell(t, t.jigsaws) else {},
			containers = byCell(t, t.containers),
			bases = if terrain then buffer.create(sx * sz * 4) else nil,
			minY = math.max(piece.y, 0),
			maxY = math.min(piece.y + sy - 1, HEIGHT - 1),
			later = {},
		})
		total += sx * sy * sz
	end

	-- Which later pieces overlap each piece's columns (a grid of GRID x GRID columns).
	local grid: { [number]: { number } } = {}
	local function eachGridCell(part: Part, visit: (key: number) -> ())
		local box = part.piece.box
		for gx = box[1] // GRID, box[4] // GRID do
			for gz = box[3] // GRID, box[6] // GRID do
				visit((gx + OFFSET) * SPAN + (gz + OFFSET))
			end
		end
	end
	for i, part in parts do
		eachGridCell(part, function(key: number)
			local list = grid[key]
			if list == nil then
				list = {}
				grid[key] = list
			end
			table.insert(list, i)
		end)
	end
	for i, part in parts do
		local box = part.piece.box
		local seen: { [number]: boolean } = {}
		eachGridCell(part, function(key: number)
			for _, j in grid[key] do
				local other = parts[j].piece.box
				if
					j > i
					and not seen[j]
					and other[1] <= box[4]
					and other[4] >= box[1]
					and other[3] <= box[6]
					and other[6] >= box[3]
				then
					seen[j] = true
					table.insert(part.later, parts[j])
				end
			end
		end)
	end

	-- Where the stream is: stage 1 the heights of terrain matching pieces (part `p`, column `c`),
	-- 2 the solid blocks at layer `y` (`active[p]`, column `c`), 3 the late blocks (part `p`,
	-- column `c`, layer `ly`), 4 done.
	local stage = 1
	local p, c, ly = 1, 0, 0
	local y = 0
	local order: { Part } = {}
	local nextPart = 1
	local active: { Part } = {}
	-- (Stage 3: the current column's world x, z and base; a tall plant's lower half was set last.)
	local cx, cz, cbase = 0, 0, 0
	local plantPending = false
	local emitted = 0

	-- Parts covering layer `y` (stage 2): drops finished ones, adds those starting. false when no
	-- part is left.
	local function enterLayer(): boolean
		local kept = 0
		for _, part in active do
			if part.maxY >= y then
				kept += 1
				active[kept] = part
			end
		end
		for k = #active, kept + 1, -1 do
			active[k] = nil
		end
		if kept == 0 then
			local nextOne = order[nextPart]
			if nextOne == nil then
				return false
			end
			y = math.max(y, nextOne.minY)
		end
		while order[nextPart] and order[nextPart].minY <= y do
			table.insert(active, order[nextPart])
			nextPart += 1
		end
		p, c = 1, 0
		return true
	end

	local plan: Plan
	plan = {
		cells = table.create(Placement.BATCH * 4),
		count = 0,
		extras = {},
		upcoming = total,
	}
	local function emit(part: Part, x: number, wy: number, z: number, block: number, index: number)
		local count = plan.count + 1
		plan.count = count
		local o = (count - 1) * 4
		local cells = plan.cells
		cells[o + 1], cells[o + 2], cells[o + 3], cells[o + 4] = x, wy, z, block
		local extra = extraOf(part, index, block)
		if extra then
			plan.extras[count] = extra
		end
		emitted += 1
	end
	local function inWorld(x: number, wy: number, z: number): boolean
		return wy >= 0 and wy < HEIGHT and math.abs(x) <= LIMIT and math.abs(z) <= LIMIT
	end

	plan.refill = function(_: Plan, budget: number): boolean
		plan.count = 0
		table.clear(plan.extras)
		local visits = 0
		local batch = Placement.BATCH
		while stage < 4 and (visits < budget and plan.count < batch or plantPending) do
			if stage == 1 then
				local part = parts[p]
				if part == nil then
					-- Every height known: the solid stage goes up through the parts by their lowest
					-- layer (ties in piece order).
					for _, each in parts do
						if each.minY <= each.maxY then
							table.insert(order, each)
						end
					end
					table.sort(order, function(a: Part, b: Part): boolean
						if a.minY ~= b.minY then
							return a.minY < b.minY
						end
						return a.rank < b.rank
					end)
					stage = 2
					y = 0
					if not enterLayer() then
						stage, p, c, ly = 3, 1, 0, 0
					end
					continue
				end
				local bases = part.bases
				if bases == nil or c >= part.sx * part.sz then
					if bases then
						-- (The layers it covers, now that its columns' heights are known.)
						local low, high = math.huge, -math.huge
						for column = 0, part.sx * part.sz - 1 do
							local base = buffer.readi32(bases, column * 4)
							low = math.min(low, base)
							high = math.max(high, base)
						end
						part.minY = math.max(low, 0)
						part.maxY = math.min(high + part.sy - 1, HEIGHT - 1)
						visits += part.sx * part.sz // 8
					end
					p, c = p + 1, 0
					continue
				end
				local lx, lz = c % part.sx, c // part.sx
				local tx, _, tz = Transform.position(lx, 0, lz, part.sx, part.sz, part.piece.rotation % 4)
				local height = firstFreeHeight(part.piece.x + tx, part.piece.z + tz)
				buffer.writei32(bases, c * 4, Jigsaw.baseY(part.piece, height))
				c += 1
				visits += HEIGHT_VISITS
			elseif stage == 2 then
				local part = active[p]
				if part == nil then
					y += 1
					if y >= HEIGHT or not enterLayer() then
						stage, p, c, ly = 3, 1, 0, 0
					end
					continue
				end
				if c >= part.sx * part.sz then
					p, c = p + 1, 0
					continue
				end
				local column = c
				c += 1
				visits += 1
				local layer = y - baseOf(part, column)
				if layer < 0 or layer >= part.sy then
					continue
				end
				local lx, lz = column % part.sx, column // part.sx
				local index = (layer * part.sz + lz) * part.sx + lx
				local block = blockOf(part, index, keepJigsaws)
				if block == nil or late(block) then
					continue
				end
				local piece = part.piece
				local tx, _, tz = Transform.position(lx, 0, lz, part.sx, part.sz, piece.rotation % 4)
				local x, z = piece.x + tx, piece.z + tz
				if inWorld(x, y, z) and not replaced(part, x, y, z, keepJigsaws) then
					emit(part, x, y, z, block, index)
				end
			else
				local part = parts[p]
				if part == nil then
					stage = 4
					break
				end
				local columns = part.sx * part.sz
				if c >= columns then
					p, c, ly = p + 1, 0, 0
					continue
				end
				local lx, lz = c % part.sx, c // part.sx
				if ly == 0 then
					local piece = part.piece
					local tx, _, tz = Transform.position(lx, 0, lz, part.sx, part.sz, piece.rotation % 4)
					cx, cz, cbase = piece.x + tx, piece.z + tz, baseOf(part, c)
				end
				if ly >= part.sy then
					c, ly = c + 1, 0
					plantPending = false
					continue
				end
				local index = (ly * part.sz + lz) * part.sx + lx
				local wy = cbase + ly
				ly += 1
				visits += 1
				local block = blockOf(part, index, keepJigsaws)
				if block == nil or not late(block) then
					continue
				end
				if inWorld(cx, wy, cz) and not replaced(part, cx, wy, cz, keepJigsaws) then
					emit(part, cx, wy, cz, block, index)
					-- (Its upper half joins this batch: the queue sets the two together.)
					plantPending = Blocks.plantTop(block) ~= nil
				end
			end
		end
		plan.upcoming = if stage == 4 then 0 else math.max(total - emitted, 0)
		return plan.count > 0 or stage < 4
	end
	return plan
end

-- Cells the pieces' templates hold in all (an upper bound of their plan's size).
function Placement.volume(pieces: { Jigsaw.Piece }, template: (name: string) -> Template?): number
	local n = 0
	for _, piece in pieces do
		local t = template(piece.template)
		if t then
			n += t.size[1] * t.size[2] * t.size[3]
		end
	end
	return n
end

--[[ The queue ]]

local Queue = {}
Queue.__index = Queue

function Queue.add(self: Queue, plan: Plan)
	if plan.count > 0 or plan.refill ~= nil then
		table.insert(self.plans, plan)
	end
end

-- (A streamed plan counts the cells it may still bring.)
function Queue.pending(self: Queue): number
	local n = -self.done
	for _, plan in self.plans do
		n += plan.count + (plan.upcoming or 0)
	end
	return math.max(n, 0)
end

--[[
	Places up to `blocks` cells (plus the upper half of a tall plant whose lower half was the last)
	and generates up to `chunks` chunks on the way; a cell whose chunk would need one more waits
	for the next step. With `seconds` (and `env.clock`) it also stops once that much time has
	passed (looked at every TIME_CHECK cells, so a slow server keeps its frame rate). Returns how
	many cells were placed.
]]
function Queue.step(self: Queue, blocks: number, chunks: number, env: Env, seconds: number?): number
	local placed = 0
	local generated = 0
	local clock = env.clock
	local deadline = if seconds and clock then clock() + seconds else nil
	local nextCheck = TIME_CHECK
	while placed < blocks do
		if deadline and placed >= nextCheck then
			nextCheck = placed + TIME_CHECK
			if (clock :: () -> number)() > deadline then
				break
			end
		end
		local plan = self.plans[1]
		if plan == nil then
			break
		end
		local i = self.done + 1
		if i > plan.count then
			local refill = plan.refill
			self.done = 0
			if refill and refill(plan, REFILL_VISITS) then
				-- (A batch may have taken a while and hold nothing yet: the clock decides.)
				if deadline and (clock :: () -> number)() > deadline then
					break
				end
				continue
			end
			table.remove(self.plans, 1)
			continue
		end
		local o = (i - 1) * 4
		local cells = plan.cells
		local x, y, z, block = cells[o + 1], cells[o + 2], cells[o + 3], cells[o + 4]
		if not env.loaded(x, z) then
			if generated >= chunks then
				break
			end
			generated += 1
			env.load(x, z)
		end
		env.setBlock(x, y, z, block)
		local extra = plan.extras[i]
		if extra then
			env.extra(x, y, z, block, extra)
		end
		self.done = i
		placed += 1
		-- A tall plant's halves go together (its chunk is the lower half's).
		local top = Blocks.plantTop(block)
		if top and i < plan.count and cells[o + 5] == x and cells[o + 6] == y + 1 and cells[o + 7] == z then
			env.setBlock(x, y + 1, z, cells[o + 8])
			self.done = i + 1
			placed += 1
		end
	end
	return placed
end

-- An empty queue.
function Placement.newQueue(): Queue
	return (setmetatable({ plans = {}, done = 0 }, Queue) :: any) :: Queue
end

-- The cells of a plan as { x, y, z, block } lists, in order (for tests and tools).
function Placement.list(plan: Plan): { { number } }
	local list = table.create(plan.count)
	for i = 1, plan.count do
		local o = (i - 1) * 4
		list[i] = { plan.cells[o + 1], plan.cells[o + 2], plan.cells[o + 3], plan.cells[o + 4] }
	end
	return list
end

return Placement

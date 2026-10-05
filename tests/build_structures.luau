--[[
	Builds the example structure's templates and writes them into the structure library.

	    lune run tests/build_structures            writes src/shared/StructureLibrary/Templates/Outpost.luau
	    lune run tests/build_structures --check    only checks that file is up to date (exit 1 if not)
	    lune run tests/build_structures --print    also prints every template's layers as ASCII

	The "outpost" (StructureLibrary/Structures.luau, pools in StructureLibrary/Pools.luau) is a small
	jigsaw structure, like a Minecraft village in miniature:
	  outpost/centres/watchtower   the start: a round gravel plaza with lantern posts and a stone
	                               watchtower (a spiral stair inside, a lookout with crenellations
	                               and a roof), paths leaving on all four sides
	  outpost/centres/ruin         or the same long abandoned: crumbling walls, rubble, an
	                               overgrown plaza and a forgotten chest in the tower
	  outpost/paths/...            terrain matching paths (straight with a house plot on each side,
	                               a crossing and two turns), so they follow the ground
	  outpost/path_ends/...        the paths' fallback pool: a lamp post, or the path fading out
	  outpost/houses/...           rigid pieces along the paths: a hut, a storehouse with a chest
	                               of supplies, an open forge and a woodpile (or nothing)
	Every piece is written here as code (boxes, rings, a deterministic dither for worn materials)
	rather than ASCII, then encoded as a structure block's SAVE would (Structures/Template.encode).
	The same templates could be built in game with structure and jigsaw blocks and saved.

	Coordinates: x west to east, z north to south, y up; layer 0 of a rigid piece is the ground's
	top layer (Jigsaw.assemble puts it there) and of a terrain matching one each column's top block.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Loader = require("./lib/Loader")

local shared, sharedRequire = Loader.mount("src/shared", "IceVoxel")
local Blocks = sharedRequire(shared.Blocks)
local Template = sharedRequire(shared.Structures.Template)
local Settings = sharedRequire(shared.Structures.Settings)
local Hash = sharedRequire(shared.Util.Hash)

local OUT = "src/shared/StructureLibrary/Templates/Outpost.luau"

type Template = any
type Items = { { slot: number, item: string, count: number, damage: number? } }

--[[ Building helpers ]]

local function id(name: string): number
	local block = Blocks.find(name)
	assert(block, `unknown block {name}`)
	return block
end

-- A builder for one template (every cell starts as "keep").
local function builder(name: string, sx: number, sy: number, sz: number)
	local t = Template.new(name, { sx, sy, sz })
	local salt = Hash.string(name)
	local b = {}

	function b.set(x: number, y: number, z: number, block: string?)
		assert(Template.inside(t, x, y, z), `{name}: {x} {y} {z} is outside`)
		Template.set(t, x, y, z, if block then id(block) else nil)
	end

	function b.get(x: number, y: number, z: number): string?
		local block = Template.get(t, x, y, z)
		return if block then Blocks.get(block).name else nil
	end

	-- Fills the box between two corners (inclusive).
	function b.fill(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, block: string?)
		for y = y0, y1 do
			for z = z0, z1 do
				for x = x0, x1 do
					b.set(x, y, z, block)
				end
			end
		end
	end

	-- A deterministic number in [0, 1) per cell, for worn and mixed materials.
	function b.noise(x: number, y: number, z: number): number
		return Hash.float3(salt, x, y, z)
	end

	-- `first` most of the time, `other` with chance `p` (per cell, deterministic).
	function b.mix(x: number, y: number, z: number, first: string, other: string, p: number): string
		return if b.noise(x, y, z) < p then other else first
	end

	-- A jigsaw block facing `front` (top Up for horizontal fronts) with its settings.
	function b.jigsaw(x: number, y: number, z: number, front: string, settings: { [string]: string })
		local top = if front == "Up" or front == "Down" then "North" else "Up"
		local block = Blocks.jigsawBlock(front, top)
		assert(block, "jigsaw orientation")
		Template.set(t, x, y, z, block)
		local defaults = Settings.defaultJigsaw(front)
		table.insert(t.jigsaws, {
			x = x,
			y = y,
			z = z,
			front = front,
			top = top,
			name = settings.name or defaults.name,
			target = settings.target or defaults.target,
			pool = settings.pool or defaults.pool,
			finalState = settings.finalState or defaults.finalState,
			joint = settings.joint or defaults.joint,
		})
	end

	-- A torch on the wall on side `wall` ("North" ...) of (x, y, z): the wall torch whose support
	-- that is (Minecraft names wall torches by the way they face, away from the wall).
	function b.wallTorch(x: number, y: number, z: number, wall: string)
		local d = Blocks.DIRECTIONS[wall]
		for _, variant in Blocks.variants(Blocks.id.Torch) do
			local dx, dy, dz = Blocks.supportOffset(variant)
			if dx == d[1] and dy == d[2] and dz == d[3] then
				Template.set(t, x, y, z, variant)
				return
			end
		end
		error(`no wall torch for a wall on the {wall}`)
	end

	-- A chest holding `items`.
	function b.chest(x: number, y: number, z: number, items: Items)
		b.set(x, y, z, "Chest")
		local list = {}
		for _, item in items do
			table.insert(list, { slot = item.slot, item = item.item, count = item.count, damage = item.damage or 0 })
		end
		table.insert(t.containers, { x = x, y = y, z = z, items = list })
	end

	function b.template(): Template
		local problem = Template.check(t)
		assert(problem == nil, `{name}: {problem}`)
		return t
	end

	return b
end

-- Jigsaw settings shared by the pieces.
local PATH_IN = { name = "outpost:path", target = "outpost:path", pool = "empty", finalState = "Gravel" }
local function pathOut(final: string)
	return { name = "outpost:path_exit", target = "outpost:path", pool = "outpost/paths", finalState = final }
end
local function houseSlot(final: string)
	return { name = "outpost:path_side", target = "outpost:house", pool = "outpost/houses", finalState = final }
end
local HOUSE_DOOR = { name = "outpost:house", target = "outpost:path_side", pool = "empty", finalState = "Air" }

-- A path cell's material: mostly gravel, worn with coarse dirt and packed mud.
local function pathBlock(b: any, x: number, z: number): string
	local n = b.noise(x, 0, z)
	return if n < 0.2 then "CoarseDirt" elseif n < 0.28 then "PackedMud" else "Gravel"
end

--[[ outpost/centres/watchtower ]]

local function watchtower(): Template
	local S, H = 13, 14
	local b = builder("outpost/centres/watchtower", S, H, S)
	local c = 6
	local function onPlaza(x: number, z: number): boolean
		return (x - c) ^ 2 + (z - c) ^ 2 <= 6.5 ^ 2
	end

	-- The plaza: gravel worn with coarse dirt, cobblestone near the tower; air above it clears the
	-- ground and trees (the corners outside the disc are kept).
	for z = 0, S - 1 do
		for x = 0, S - 1 do
			if onPlaza(x, z) then
				local d = math.max(math.abs(x - c), math.abs(z - c))
				local floor = if d <= 3
					then b.mix(x, 0, z, "Cobblestone", "Gravel", 0.15)
					else b.mix(x, 0, z, "Gravel", "CoarseDirt", 0.3)
				b.set(x, 0, z, floor)
				b.fill(x, 1, z, x, H - 1, z, "Air")
			end
		end
	end

	-- Lantern posts on the plaza.
	for _, p in { { 2, 2 }, { 10, 2 }, { 2, 10 }, { 10, 10 } } do
		b.set(p[1], 1, p[2], "Cobblestone")
		b.set(p[1], 2, p[2], "Lantern")
	end

	-- The tower: 5 x 5 (x and z 4..8), spruce log corners, worn stone brick walls up to layer 6.
	local lo, hi = 4, 8
	for y = 1, 6 do
		for z = lo, hi do
			for x = lo, hi do
				local edgeX, edgeZ = x == lo or x == hi, z == lo or z == hi
				if edgeX and edgeZ then
					b.set(x, y, z, "SpruceLog")
				elseif edgeX or edgeZ then
					local n = b.noise(x, y, z)
					local wall = if n < 0.18
						then "CrackedStoneBricks"
						elseif n < 0.3 then "Cobblestone"
						else "StoneBricks"
					b.set(x, y, z, if y == 1 then "Cobblestone" else wall)
				end
			end
		end
	end
	-- Door (south), arrow slits (north, west, east).
	b.fill(c, 1, hi, c, 2, hi, "Air")
	b.set(c, 4, lo, "Air")
	b.set(lo, 4, c, "Air")
	b.set(hi, 4, c, "Air")
	-- A torch over the door, inside.
	b.wallTorch(c, 3, hi - 1, "South")

	-- The spiral stair: a log pillar in the middle, steps around it clockwise from the door's
	-- west side, one block higher each (players step up one block).
	b.fill(c, 1, c, c, 6, c, "SpruceLog")
	local steps = { { 5, 7 }, { 5, 6 }, { 5, 5 }, { 6, 5 }, { 7, 5 }, { 7, 6 } }
	for i, s in steps do
		b.set(s[1], i, s[2], "SprucePlanks")
	end

	-- The lookout: a 7 x 7 floor over the walls (holes over the last steps), crenellations, corner
	-- posts and a stepped roof with a lantern hanging under it.
	b.fill(lo - 1, 7, lo - 1, hi + 1, 7, hi + 1, "SprucePlanks")
	b.set(7, 7, 5, "Air")
	b.set(7, 7, 6, "Air")
	for z = lo - 1, hi + 1 do
		for x = lo - 1, hi + 1 do
			local edge = x == lo - 1 or x == hi + 1 or z == lo - 1 or z == hi + 1
			local corner = (x == lo - 1 or x == hi + 1) and (z == lo - 1 or z == hi + 1)
			if corner then
				b.fill(x, 8, z, x, 10, z, "SpruceLog")
			elseif edge and (x + z) % 2 == 0 then
				b.set(x, 8, z, b.mix(x, 8, z, "StoneBricks", "Cobblestone", 0.3))
			end
		end
	end
	b.fill(lo - 1, 11, lo - 1, hi + 1, 11, hi + 1, "SprucePlanks")
	b.fill(lo, 12, lo, hi, 12, hi, "SprucePlanks")
	b.fill(lo + 1, 13, lo + 1, hi - 1, 13, hi - 1, "SpruceLog")
	b.set(c, 10, c, "HangingLantern")

	-- Paths leave the plaza on every side.
	b.jigsaw(c, 0, 0, "North", pathOut("Gravel"))
	b.jigsaw(S - 1, 0, c, "East", pathOut("Gravel"))
	b.jigsaw(c, 0, S - 1, "South", pathOut("Gravel"))
	b.jigsaw(0, 0, c, "West", pathOut("Gravel"))
	return b.template()
end

--[[ outpost/centres/ruin: the same plaza and tower, long abandoned (the start pool picks one of
	the two) ]]

local function ruin(): Template
	local S, H = 13, 9
	local b = builder("outpost/centres/ruin", S, H, S)
	local c = 6
	local function onPlaza(x: number, z: number): boolean
		return (x - c) ^ 2 + (z - c) ^ 2 <= 6.5 ^ 2
	end

	-- An overgrown plaza: its edge gone back to grass (kept), rubble around the tower.
	for z = 0, S - 1 do
		for x = 0, S - 1 do
			if onPlaza(x, z) then
				local d = math.sqrt((x - c) ^ 2 + (z - c) ^ 2)
				if d < 4 or b.noise(x, 2, z) > (d - 4) / 3 then
					local floor = if d <= 3.5
						then b.mix(x, 0, z, "Cobblestone", "CoarseDirt", 0.3)
						else b.mix(x, 0, z, "Gravel", "CoarseDirt", 0.45)
					b.set(x, 0, z, floor)
				end
				b.fill(x, 1, z, x, H - 1, z, "Air")
				if d > 3 and d < 5.5 and b.noise(x, 1, z) < 0.18 then
					b.set(x, 1, z, b.mix(x, 1, z, "CrackedStoneBricks", "Cobblestone", 0.5))
				end
			end
		end
	end

	-- Lantern posts: two still stand (without their lanterns), two are stumps.
	for i, p in { { 2, 2 }, { 10, 2 }, { 2, 10 }, { 10, 10 } } do
		b.set(p[1], 1, p[2], "Cobblestone")
		if i % 2 == 1 then
			b.set(p[1], 2, p[2], "Cobblestone")
		end
	end

	-- The tower's walls crumble more the higher they are; the corner logs end at random heights.
	local lo, hi = 4, 8
	for z = lo, hi do
		for x = lo, hi do
			local edgeX, edgeZ = x == lo or x == hi, z == lo or z == hi
			if edgeX and edgeZ then
				local top = 3 + math.floor(b.noise(x, 9, z) * 5)
				b.fill(x, 1, z, x, top, z, "SpruceLog")
			elseif edgeX or edgeZ then
				for y = 1, 7 do
					if b.noise(x, y, z) < 1 - (y - 1) * 0.13 then
						local n = b.noise(x, y + 20, z)
						local wall = if n < 0.4
							then "CrackedStoneBricks"
							elseif n < 0.6 then "Cobblestone"
							else "StoneBricks"
						b.set(x, y, z, if y == 1 then "Cobblestone" else wall)
					end
				end
			end
		end
	end
	b.fill(c, 1, hi, c, 2, hi, "Air")

	-- What is left of the stair and the lookout floor.
	b.fill(c, 1, c, c, 4, c, "SpruceLog")
	local steps = { { 5, 7 }, { 5, 6 }, { 5, 5 }, { 6, 5 } }
	for i, s in steps do
		b.set(s[1], i, s[2], "SprucePlanks")
	end
	for z = lo - 1, hi + 1 do
		for x = lo - 1, hi + 1 do
			if b.noise(x, 7, z) < 0.25 and (x == lo or x == hi or z == lo or z == hi) then
				b.set(x, 7, z, "SprucePlanks")
			end
		end
	end

	-- Someone's stash, left behind in the corner by the door.
	b.chest(7, 1, 7, {
		{ slot = 3, item = "Coal", count = 4 },
		{ slot = 7, item = "IronNugget", count = 9 },
		{ slot = 12, item = "GoldNugget", count = 5 },
		{ slot = 15, item = "Emerald", count = 1 },
		{ slot = 20, item = "IronSword", count = 1, damage = 180 },
		{ slot = 26, item = "Stick", count = 3 },
	})

	b.jigsaw(c, 0, 0, "North", pathOut("Gravel"))
	b.jigsaw(S - 1, 0, c, "East", pathOut("Gravel"))
	b.jigsaw(c, 0, S - 1, "South", pathOut("Gravel"))
	b.jigsaw(0, 0, c, "West", pathOut("Gravel"))
	return b.template()
end

--[[ Paths (terrain matching: each column's layer 0 replaces its top block) ]]

-- Path pieces are 3 tall: only layer 0 is written, the rest (kept) reserves room above the path
-- so houses and other paths keep clear of it.
local PATH_HEIGHT = 3

local function straight(): Template
	local b = builder("outpost/paths/straight", 3, PATH_HEIGHT, 9)
	for z = 0, 8 do
		for x = 0, 2 do
			-- Ragged edges: some edge cells keep the ground.
			if x == 1 or b.noise(x, 1, z) > 0.2 then
				b.set(x, 0, z, pathBlock(b, x, z))
			end
		end
	end
	b.jigsaw(1, 0, 0, "North", PATH_IN)
	b.jigsaw(1, 0, 8, "South", pathOut("Gravel"))
	b.jigsaw(0, 0, 4, "West", houseSlot("CoarseDirt"))
	b.jigsaw(2, 0, 4, "East", houseSlot("CoarseDirt"))
	return b.template()
end

local function crossing(): Template
	local b = builder("outpost/paths/crossing", 5, PATH_HEIGHT, 5)
	for z = 0, 4 do
		for x = 0, 4 do
			local corner = (x == 0 or x == 4) and (z == 0 or z == 4)
			if not corner then
				b.set(x, 0, z, pathBlock(b, x, z))
			end
		end
	end
	b.jigsaw(2, 0, 0, "North", PATH_IN)
	b.jigsaw(2, 0, 4, "South", pathOut("Gravel"))
	b.jigsaw(0, 0, 2, "West", pathOut("Gravel"))
	b.jigsaw(4, 0, 2, "East", pathOut("Gravel"))
	return b.template()
end

-- A bend from the north edge to the east (or west) edge.
local function turn(east: boolean): Template
	local b = builder(if east then "outpost/paths/turn_east" else "outpost/paths/turn_west", 5, PATH_HEIGHT, 5)
	for z = 0, 4 do
		for x = 0, 4 do
			-- The path's middle line runs from (2, 0) down to (2, 2), then out to the side.
			local mx = if east then x else 4 - x
			local along = math.abs(mx - 2) <= 1 and z <= 3
			local out = mx >= 1 and math.abs(z - 2) <= 1
			if (along or out) and not (mx == 1 and z == 3 and b.noise(x, 1, z) < 0.5) then
				b.set(x, 0, z, pathBlock(b, x, z))
			end
		end
	end
	b.jigsaw(2, 0, 0, "North", PATH_IN)
	if east then
		b.jigsaw(4, 0, 2, "East", pathOut("Gravel"))
	else
		b.jigsaw(0, 0, 2, "West", pathOut("Gravel"))
	end
	return b.template()
end

local function lampEnd(): Template
	local b = builder("outpost/path_ends/lamp", 3, 4, 3)
	for z = 0, 1 do
		for x = 0, 2 do
			if x == 1 or b.noise(x, 1, z) > 0.3 then
				b.set(x, 0, z, pathBlock(b, x, z))
			end
		end
	end
	b.set(1, 0, 2, "Cobblestone")
	b.set(1, 1, 2, "Cobblestone")
	b.set(1, 2, 2, "SpruceLog")
	b.set(1, 3, 2, "Lantern")
	b.jigsaw(1, 0, 0, "North", PATH_IN)
	return b.template()
end

local function fadeEnd(): Template
	local b = builder("outpost/path_ends/fade", 3, 1, 2)
	b.set(0, 0, 0, "CoarseDirt")
	b.set(2, 0, 0, "Gravel")
	b.set(1, 0, 1, "CoarseDirt")
	b.jigsaw(1, 0, 0, "North", PATH_IN)
	return b.template()
end

--[[ Houses (rigid). Each is 5 wide and 5 deep with a doorstep row in front (z = 5): the door
	jigsaw sits there at layer 1, facing the path, so the floor (layer 0) is level with the ground
	at the path's edge. ]]

local function doorstep(b: any, block: string)
	b.set(2, 0, 5, block)
	b.jigsaw(2, 1, 5, "South", HOUSE_DOOR)
end

-- Walls around x and z 0..4 from layer y0 to y1 with log corners.
local function walls(b: any, y0: number, y1: number, corner: string, wall: (x: number, y: number, z: number) -> string)
	for y = y0, y1 do
		for z = 0, 4 do
			for x = 0, 4 do
				local edgeX, edgeZ = x == 0 or x == 4, z == 0 or z == 4
				if edgeX and edgeZ then
					b.set(x, y, z, corner)
				elseif edgeX or edgeZ then
					b.set(x, y, z, wall(x, y, z))
				else
					b.set(x, y, z, "Air")
				end
			end
		end
	end
end

-- A stepped gable roof over x and z 0..4 (and the doorstep), ridge along z.
local function roof(b: any, y: number, block: string, ridge: string)
	b.fill(0, y, 0, 4, y, 4, block)
	b.fill(1, y, 5, 3, y, 5, block)
	b.fill(1, y + 1, 0, 3, y + 1, 4, block)
	b.fill(2, y + 2, 0, 2, y + 2, 4, ridge)
end

local function hut(): Template
	local b = builder("outpost/houses/hut", 5, 7, 6)
	b.fill(0, 0, 0, 4, 0, 4, "Cobblestone")
	walls(b, 1, 3, "OakLog", function(x, y, z)
		return b.mix(x, y, z, "Planks", "SprucePlanks", 0.15)
	end)
	b.fill(2, 1, 4, 2, 2, 4, "Air")
	b.set(0, 2, 2, "Glass")
	b.set(4, 2, 2, "Glass")
	b.wallTorch(2, 2, 1, "North")
	b.set(1, 1, 1, "CraftingTable")
	roof(b, 4, "SprucePlanks", "SpruceLog")
	doorstep(b, "Cobblestone")
	return b.template()
end

local function storehouse(): Template
	local b = builder("outpost/houses/storehouse", 5, 7, 6)
	b.fill(0, 0, 0, 4, 0, 4, "Planks")
	walls(b, 1, 3, "SpruceLog", function(x, y, z)
		return if y == 1 then "Cobblestone" else "Planks"
	end)
	b.fill(2, 1, 4, 2, 2, 4, "Air")
	b.set(2, 2, 0, "Glass")
	b.wallTorch(1, 2, 1, "West")
	-- Supplies: a chest, a log pile and a furnace.
	b.chest(1, 1, 1, {
		{ slot = 2, item = "Coal", count = 7 },
		{ slot = 5, item = "IronIngot", count = 3 },
		{ slot = 9, item = "Torch", count = 12 },
		{ slot = 13, item = "StonePickaxe", count = 1, damage = 41 },
		{ slot = 17, item = "Emerald", count = 2 },
		{ slot = 21, item = "IronNugget", count = 6 },
		{ slot = 24, item = "Stick", count = 5 },
	})
	b.set(3, 1, 1, "OakLog")
	b.set(3, 1, 2, "OakLog")
	b.set(3, 2, 1, "OakLog")
	b.set(1, 1, 3, "Furnace")
	roof(b, 4, "Planks", "OakLog")
	doorstep(b, "Planks")
	return b.template()
end

local function forge(): Template
	local b = builder("outpost/houses/forge", 5, 7, 6)
	for z = 0, 4 do
		for x = 0, 4 do
			b.set(x, 0, z, b.mix(x, 0, z, "SmoothStone", "Cobblestone", 0.35))
		end
	end
	-- Open on three sides: a brick back wall, two posts in front, air between.
	b.fill(0, 1, 1, 4, 3, 4, "Air")
	b.fill(0, 1, 4, 0, 3, 4, "SpruceLog")
	b.fill(4, 1, 4, 4, 3, 4, "SpruceLog")
	for x = 0, 4 do
		for y = 1, 3 do
			b.set(x, y, 0, b.mix(x, y, 0, "Brick", "Cobblestone", 0.25))
		end
	end
	b.set(1, 1, 1, "Furnace")
	b.set(2, 1, 1, "Furnace")
	b.set(3, 1, 1, "CraftingTable")
	-- (An anvil's stand-in.)
	b.set(3, 1, 3, "Cobblestone")
	-- The roof with a lantern under it, and the chimney over the furnaces.
	b.fill(0, 4, 0, 4, 4, 4, "SprucePlanks")
	b.fill(1, 4, 5, 3, 4, 5, "SprucePlanks")
	b.fill(1, 5, 1, 3, 5, 4, "SprucePlanks")
	b.fill(1, 4, 0, 2, 6, 0, "Brick")
	b.set(2, 3, 2, "HangingLantern")
	doorstep(b, "SmoothStone")
	return b.template()
end

local function woodpile(): Template
	local b = builder("outpost/houses/woodpile", 5, 4, 6)
	for z = 0, 4 do
		for x = 0, 4 do
			if b.noise(x, 0, z) < 0.6 or (x >= 1 and x <= 3 and z <= 3) then
				b.set(x, 0, z, b.mix(x, 0, z, "CoarseDirt", "Podzol", 0.4))
			end
			b.fill(x, 1, z, x, 3, z, "Air")
		end
	end
	-- Two log stacks and a chopping block.
	b.fill(0, 1, 0, 1, 2, 1, "OakLog")
	b.set(0, 3, 0, "OakLog")
	b.fill(3, 1, 0, 4, 1, 1, "SpruceLog")
	b.set(4, 2, 0, "SpruceLog")
	b.set(2, 1, 2, "OakLog")
	b.set(4, 1, 3, "CraftingTable")
	doorstep(b, "CoarseDirt")
	return b.template()
end

--[[ Writing the module ]]

local templates: { Template } = {
	watchtower(),
	ruin(),
	straight(),
	crossing(),
	turn(true),
	turn(false),
	lampEnd(),
	fadeEnd(),
	hut(),
	storehouse(),
	forge(),
	woodpile(),
}

local lines = {
	"--!strict",
	"--[[",
	'\tThe example structure "outpost" (StructureLibrary/Structures.luau; pools in Pools.luau): a',
	"\twatchtower plaza (or its ruin, with a forgotten chest), terrain matching paths with lamp",
	"\tposts at their ends, and a hut, a storehouse with a chest of supplies, an open forge and a",
	"\twoodpile along them.",
	"",
	"\tGenerated by tests/build_structures.luau (`lune run tests/build_structures`): edit that and",
	"\trebuild rather than this file. `lune run tests/structure decode " .. OUT .. "` prints the",
	"\tpieces.",
	"]]",
	"",
	"return {",
}
for _, t in templates do
	local text = Template.encode(t)
	local back, err = Template.decode(text)
	assert(back, `{t.name}: {err}`)
	local same, why = Template.equal(t, back)
	assert(same, `{t.name} does not survive encoding: {why}`)
	table.insert(lines, `\t-- {t.name}: {t.size[1]} x {t.size[2]} x {t.size[3]}, {Template.count(t)} blocks`)
	table.insert(lines, `\t"{text}",`)
end
table.insert(lines, "}")
table.insert(lines, "")
local source = table.concat(lines, "\n")

if table.find(process.args, "--print") then
	for _, t in templates do
		local tt = Template.toTable(t)
		print(`\n{t.name} ({t.size[1]} x {t.size[2]} x {t.size[3]})`)
		local legend = {}
		for symbol, name in tt.legend do
			table.insert(legend, `{symbol}={name}`)
		end
		table.sort(legend)
		print("  " .. table.concat(legend, " "))
		for y, rows in tt.layers do
			print(`  y = {y - 1}`)
			for _, row in rows do
				print("    " .. row)
			end
		end
	end
end

if table.find(process.args, "--check") then
	local current = if fs.isFile(OUT) then fs.readFile(OUT) else ""
	if current ~= source then
		print(`{OUT} is out of date: run lune run tests/build_structures`)
		process.exit(1)
	end
	print(`{OUT} is up to date ({#templates} templates)`)
else
	fs.writeFile(OUT, source)
	print(`wrote {OUT}: {#templates} templates, {#source} characters`)
end

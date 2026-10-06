--!strict
--[[
	Fire, the rules the server and the clients share (pure, tested in tests/spec/Fire): Minecraft
	1.20.1's FireBlock and BaseFireBlock, with the odds of each block from Blocks (BlockList
	`flammable`; FireBlock.bootStrap). The server's Behaviours/Fire spreads and burns it out;
	the client's Rendering/FireRenderer draws it.

	  Burning     `canBurn(block)` (FireBlock.canBurn: ignite odds above 0) and
	              `igniteOddsAt(getBlock, x, y, z)` (FireBlock.getIgniteOdds: an empty cell takes the
	              highest ignite odds of its six neighbours, anything else 0).
	  Survival    `canSurvive` (FireBlock.canSurvive): a sturdy block below (Blocks.isSturdy, the
	              isFaceSturdy(UP) of Minecraft) or a flammable neighbour on any of the six sides
	              (`isValidLocation`, FireBlock.isValidFireLocation). nil when that depends on a
	              block that is not loaded, so the server waits instead of guessing.
	              `canPlaceAt` (BaseFireBlock.canBePlacedAt, no portals here): empty and survives;
	              where flint and steel, lava and spreading may put fire.
	  Sides       `sides` (FireBlock.getStateForPlacement): on a block that burns or is sturdy the
	              fire stands on the floor (0); else it clings to the flammable neighbours, a flag
	              each (NORTH, EAST, SOUTH, WEST, UP). Minecraft keeps them as block state; here
	              every client works them out from the neighbours (the same answer), so the block
	              stays the single Fire id (other modules only ever compare with Blocks.id.Fire).
	  Outline     `outline(sides)`: Minecraft's shapes, a pixel thick slab on the floor
	              (BaseFireBlock.DOWN_AABB), or the slabs on the walls (and ceiling) it clings to,
	              as one box around them; `outlineAt(getBlock)` gives the aim's outline function
	              (VoxelRaycast's, by position).
	  Planes      `planes(sides)`: where the flames are drawn, in pixels from the cell's centre
	              (Minecraft's models, blockstates/fire.json):
	                * on the floor, template_fire_floor's four planes, 16 wide and 22.4 tall
	                  (rescaled by 1 / cos 22.5), a pair at x = 8 +- 0.8 leaning +-22.5 degrees
	                  about Z and a pair at z = 8 +- 0.8 leaning about X, crossing in the middle,
	                  seen from both sides; and its four sides, here one box of the cell's size,
	                  22.4 pixels tall, with the flames on its four outer faces (Minecraft draws
	                  four planes 0.01 pixels in, seen from both sides: the far ones from inside
	                  are left out, which saves a part and four images a fire);
	                * clinging, template_fire_side's plane against each flammable wall (16 x
	                  22.4, 0.01 pixels off it), facing into the cell, and template_fire_up's
	                  under a flammable ceiling, facing down.
	              A campfire (BlockList Campfire, always lit) has flames too: campfire.json's two
	              planes, 16 pixels tall from a pixel above the floor, crossing diagonally through
	              the middle (14.4 wide along a side, turned 45 degrees about the vertical and
	              rescaled by 1 / cos 45, so 20.4 wide), seen from both sides. `isFlame` is fire
	              or a campfire, `lookAt` the look of either (a campfire's is CAMPFIRE_LOOK, past
	              the flags), and `planes(CAMPFIRE_LOOK)` its planes.
	              Each plane has a `size` (width, height; the depth is the renderer's), an
	              `offset`, an `orientation` (degrees, Roblox's YXZ order: CFrame.fromOrientation)
	              and its `faces`: "double" (Front and Back), "front" (Front only, the face along
	              the part's look vector) or "box" (the four sides of a box, outwards).
	  Animation   the user's texture `TEXTURE`: FRAMES (8) square frames stacked from top to
	              bottom in one sheet (uploaded 256 x 2048; Roblox shrinks images over 1024 pixels,
	              so in game it is 128 x 1024: the frames are never cut by pixels). Every fire shows
	              the same frame (Minecraft animates the fire texture once for every fire),
	              FRAME_TICKS (2) game ticks each, so the flames loop every 0.8 s: `frameAt(seconds)`,
	              and `sheetPosition(frame)`: the sheet is drawn FRAMES planes tall behind each
	              plane, which shows (clips) one of them, moved up a plane per frame.
]]

local Blocks = require(script.Parent.Blocks)

export type GetBlock = (x: number, y: number, z: number) -> number?

-- Where the flames of a fire are drawn (see the header).
export type Plane = {
	size: { number },
	offset: { number },
	orientation: { number },
	faces: string,
}

local Fire = {}

Fire.BLOCK = Blocks.id.Fire
-- The campfire, whose flames are drawn like fire's (see the header).
Fire.CAMPFIRE = Blocks.id.Campfire
-- Minecraft's FireBlock.MAX_AGE.
Fire.MAX_AGE = 15

-- The sides a fire clings to (Minecraft's NORTH, EAST, SOUTH, WEST and UP properties), as flags.
Fire.NORTH = 1
Fire.EAST = 2
Fire.SOUTH = 4
Fire.WEST = 8
Fire.UP = 16
-- The look of a campfire's flames (`lookAt`, `planes`): past every combination of the flags.
Fire.CAMPFIRE_LOOK = 32
-- Each flag's neighbour, in Minecraft's Direction order (PROPERTY_BY_DIRECTION).
local SIDES: { { number } } = {
	{ Fire.NORTH, 0, 0, -1 },
	{ Fire.EAST, 1, 0, 0 },
	{ Fire.SOUTH, 0, 0, 1 },
	{ Fire.WEST, -1, 0, 0 },
	{ Fire.UP, 0, 1, 0 },
}
-- The six neighbours (Direction.values(): down, up, north, south, west, east).
local NEIGHBOURS: { { number } } = {
	{ 0, -1, 0 },
	{ 0, 1, 0 },
	{ 0, 0, -1 },
	{ 0, 0, 1 },
	{ -1, 0, 0 },
	{ 1, 0, 0 },
}
Fire.NEIGHBOURS = NEIGHBOURS

-- The user's fire texture: 8 square frames stacked in one sheet, top first (any resolution).
Fire.TEXTURE = "rbxassetid://124923986221566"
Fire.FRAMES = 8
-- Game ticks each frame shows (Minecraft's fire texture steps every tick through 32 frames; 8
-- frames at 2 ticks keep it as lively without looping too fast).
Fire.FRAME_TICKS = 2
Fire.TICK_RATE = 20

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local FIRE = Fire.BLOCK
local CAMPFIRE = Fire.CAMPFIRE

--[[ Burning ]]

-- Is `block` empty (air or cave air: Minecraft's isEmptyBlock)? false for unknown blocks.
function Fire.isEmpty(block: number?): boolean
	return block == AIR or block == CAVE_AIR
end

-- Does fire catch on `block` (FireBlock.canBurn)? false for unknown (unloaded) blocks.
function Fire.canBurn(block: number?): boolean
	return block ~= nil and Blocks.isFlammable(block)
end

--[[
	FireBlock.getIgniteOdds(level, pos): 0 unless (x, y, z) is empty, else the highest ignite odds
	of its six neighbours (unloaded ones count 0).
]]
function Fire.igniteOddsAt(getBlock: GetBlock, x: number, y: number, z: number): number
	if not Fire.isEmpty(getBlock(x, y, z)) then
		return 0
	end
	local best = 0
	for _, d in NEIGHBOURS do
		local block = getBlock(x + d[1], y + d[2], z + d[3])
		if block ~= nil then
			best = math.max(best, Blocks.igniteOdds(block))
		end
	end
	return best
end

--[[ Survival ]]

--[[
	FireBlock.isValidFireLocation: a flammable block on any of the six sides. nil when none is but
	a neighbour is not loaded.
]]
function Fire.isValidLocation(getBlock: GetBlock, x: number, y: number, z: number): boolean?
	local unknown = false
	for _, d in NEIGHBOURS do
		local block = getBlock(x + d[1], y + d[2], z + d[3])
		if block == nil then
			unknown = true
		elseif Blocks.isFlammable(block) then
			return true
		end
	end
	return if unknown then nil else false
end

--[[
	Can fire stay at (x, y, z) (FireBlock.canSurvive)? A sturdy block below, or a flammable one on
	any side. nil when the answer depends on a block that is not loaded.
]]
function Fire.canSurvive(getBlock: GetBlock, x: number, y: number, z: number): boolean?
	local below = getBlock(x, y - 1, z)
	if below ~= nil and Blocks.isSturdy(below) then
		return true
	end
	local valid = Fire.isValidLocation(getBlock, x, y, z)
	if valid == false and below == nil then
		return nil
	end
	return valid
end

--[[
	May fire be put at (x, y, z) (BaseFireBlock.canBePlacedAt)? It must be empty and the fire must
	survive there (known blocks only).
]]
function Fire.canPlaceAt(getBlock: GetBlock, x: number, y: number, z: number): boolean
	return Fire.isEmpty(getBlock(x, y, z)) and Fire.canSurvive(getBlock, x, y, z) == true
end

--[[ How it looks: the sides it clings to, its outline, its planes ]]

--[[
	The sides the fire at (x, y, z) clings to (FireBlock.getStateForPlacement): 0 when it burns on
	the floor (the block below is flammable or sturdy), else the flags of its flammable
	neighbours. Unknown neighbours hold nothing.
]]
function Fire.sides(getBlock: GetBlock, x: number, y: number, z: number): number
	local below = getBlock(x, y - 1, z)
	if below ~= nil and (Blocks.isFlammable(below) or Blocks.isSturdy(below)) then
		return 0
	end
	local flags = 0
	for _, side in SIDES do
		if Fire.canBurn(getBlock(x + side[2], y + side[3], z + side[4])) then
			flags += side[1]
		end
	end
	return flags
end

-- Minecraft's shapes (block units within the cell), by flag, and on the floor.
local SLABS: { [number]: { number } } = {
	[Fire.NORTH] = { 0, 0, 0, 1, 1, 1 / 16 },
	[Fire.EAST] = { 15 / 16, 0, 0, 1, 1, 1 },
	[Fire.SOUTH] = { 0, 0, 15 / 16, 1, 1, 1 },
	[Fire.WEST] = { 0, 0, 0, 1 / 16, 1, 1 },
	[Fire.UP] = { 0, 15 / 16, 0, 1, 1, 1 },
}
local FLOOR_SLAB = table.freeze({ 0, 0, 0, 1, 1 / 16, 1 })
local outlines: { [number]: { number } } = { [0] = FLOOR_SLAB }
for flags = 1, 31 do
	local box = { math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge }
	for flag, slab in SLABS do
		if bit32.btest(flags, flag) then
			for k = 1, 3 do
				box[k] = math.min(box[k], slab[k])
				box[k + 3] = math.max(box[k + 3], slab[k + 3])
			end
		end
	end
	outlines[flags] = table.freeze(box)
end

--[[
	The outline of a fire clinging to `sides` (block units within its cell, as Blocks.outline:
	min x, y, z, max x, y, z): the floor slab, else one box around the slabs of its sides. Read only.
]]
function Fire.outline(sides: number): { number }
	return outlines[sides] or FLOOR_SLAB
end

--[[
	The outline function an aim needs (VoxelRaycast.cast's `outline`, Blocks.outline's by
	position): a fire's from its sides there, every other block's from Blocks.outline.
]]
function Fire.outlineAt(getBlock: GetBlock): (block: number, x: number, y: number, z: number) -> { number }?
	return function(block: number, x: number, y: number, z: number): { number }?
		if block == FIRE then
			return Fire.outline(Fire.sides(getBlock, x, y, z))
		end
		return Blocks.outline(block)
	end
end

--[[
	A plane of template_fire_floor: Minecraft's element from (0, 0, 8 + across) to (16, 22.4,
	8 + across) along X (`axis` "x"; along Z: from (8 + across, 0, 0) to (8 + across, 22.4, 16)),
	turned `angle` degrees about that axis through the cell's centre with `rescale` (the turned
	axes stretched by 1 / cos 22.5, so it still reaches the cell's edges).
]]
local RESCALE = 1 / math.cos(math.rad(22.5))
local function floorPlane(axis: string, across: number, angle: number): Plane
	local t = math.rad(angle)
	local c, s = math.cos(t), math.sin(t)
	-- (The element's centre from the cell's centre: 11.2 - 8 up, `across` off the axis.)
	local up = 22.4 / 2 - 8
	if axis == "x" then
		-- About +X (right-handed): y' = y c - z s, z' = y s + z c.
		return {
			size = { 16, 22.4 * RESCALE },
			offset = { 0, (up * c - across * s) * RESCALE, (up * s + across * c) * RESCALE },
			orientation = { angle, 0, 0 },
			faces = "double",
		}
	end
	-- About +Z: x' = x c - y s, y' = x s + y c. The plane spans Z, so it is the X plane turned a
	-- quarter about Y, then leaning the other way (Ry(90) Rx(-angle) is Rz(angle) Ry(90)).
	return {
		size = { 16, 22.4 * RESCALE },
		offset = { (across * c - up * s) * RESCALE, (across * s + up * c) * RESCALE, 0 },
		orientation = { -angle, 90, 0 },
		faces = "double",
	}
end

local FLOOR: { Plane } = {
	floorPlane("x", 0.8, -22.5),
	floorPlane("x", -0.8, 22.5),
	-- (Leaning the same way as the first pair: inwards, crossing the middle. Turning about +Z
	-- tips the top the other way from turning about +X, so the signs swap.)
	floorPlane("z", 0.8, 22.5),
	floorPlane("z", -0.8, -22.5),
	-- template_fire_side on all four sides, as one box (see the header).
	{ size = { 16, 22.4, 16 }, offset = { 0, 22.4 / 2 - 8, 0 }, orientation = { 0, 0, 0 }, faces = "box" },
}

-- template_fire_side against each wall, 0.01 pixels off it, facing into the cell (the look
-- vector of orientation (0, yaw, 0) is (-sin yaw, 0, -cos yaw)).
local WALL = 8 - 0.01
local SIDE_PLANES: { [number]: Plane } = {
	[Fire.NORTH] = { size = { 16, 22.4 }, offset = { 0, 3.2, -WALL }, orientation = { 0, 180, 0 }, faces = "front" },
	[Fire.EAST] = { size = { 16, 22.4 }, offset = { WALL, 3.2, 0 }, orientation = { 0, 90, 0 }, faces = "front" },
	[Fire.SOUTH] = { size = { 16, 22.4 }, offset = { 0, 3.2, WALL }, orientation = { 0, 0, 0 }, faces = "front" },
	[Fire.WEST] = { size = { 16, 22.4 }, offset = { -WALL, 3.2, 0 }, orientation = { 0, -90, 0 }, faces = "front" },
	-- template_fire_up: under the ceiling, facing down (Rx(-90) turns the look vector down).
	[Fire.UP] = { size = { 16, 16 }, offset = { 0, WALL, 0 }, orientation = { -90, 0, 0 }, faces = "front" },
}

local planeLists: { [number]: { Plane } } = { [0] = table.freeze(FLOOR) }
for flags = 1, 31 do
	local list: { Plane } = {}
	for _, side in SIDES do
		if bit32.btest(flags, side[1]) then
			table.insert(list, SIDE_PLANES[side[1]])
		end
	end
	planeLists[flags] = table.freeze(list)
end

-- campfire.json's flames (see the header): two planes crossing diagonally, from a pixel above
-- the floor to 17.
local CAMPFIRE_WIDTH = 14.4 / math.cos(math.rad(45))
planeLists[Fire.CAMPFIRE_LOOK] = table.freeze({
	{ size = { CAMPFIRE_WIDTH, 16 }, offset = { 0, 1, 0 }, orientation = { 0, 45, 0 }, faces = "double" },
	{ size = { CAMPFIRE_WIDTH, 16 }, offset = { 0, 1, 0 }, orientation = { 0, -45, 0 }, faces = "double" },
} :: { Plane })

--[[
	The planes a fire clinging to `sides` is drawn with, or a campfire's for CAMPFIRE_LOOK (see
	the header). Read only.
]]
function Fire.planes(sides: number): { Plane }
	return planeLists[sides] or planeLists[0]
end

-- Does `block` show flames (fire or a campfire)?
function Fire.isFlame(block: number?): boolean
	return block == FIRE or block == CAMPFIRE
end

--[[
	The look of the flames at (x, y, z), for `planes`: a campfire's CAMPFIRE_LOOK, else the sides
	the fire there clings to (`sides`).
]]
function Fire.lookAt(getBlock: GetBlock, x: number, y: number, z: number): number
	if getBlock(x, y, z) == CAMPFIRE then
		return Fire.CAMPFIRE_LOOK
	end
	return Fire.sides(getBlock, x, y, z)
end

--[[ Animation ]]

-- The frame (0 .. FRAMES - 1) every fire shows `seconds` into the game (any clock).
function Fire.frameAt(seconds: number): number
	return math.floor(seconds * Fire.TICK_RATE / Fire.FRAME_TICKS) % Fire.FRAMES
end

--[[
	Where the sheet goes behind a plane to show `frame`: its top, in plane heights (the Y scale of
	the ImageLabel's Position; the label is 1 wide and FRAMES tall). Frames go down from the top,
	so frame f moves the sheet up f planes. In heights, not pixels: whatever size Roblox keeps the
	image at, a plane shows exactly one frame.
]]
function Fire.sheetPosition(frame: number): number
	return -(frame % Fire.FRAMES)
end

return Fire
